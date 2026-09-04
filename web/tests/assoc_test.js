// B8 harness: associationSection + resolutionLadder + demo-data ripples.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice } = require("./srcslice");
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo' };
global.isLive = ()=> CFG.mode==='live';
global.localStorage = { getItem:()=>null, setItem:()=>{}, removeItem:()=>{} };
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = Number(NOWm[1].replace(/_/g,''));
const BSm = src.match(/const BLOCK_SECS\s*=\s*([0-9_]+)/); global.BLOCK_SECS = Number(BSm[1].replace(/_/g,''));

let code = '';
code += slice('const SETTLE_DELAY', '\n').replace('const ','var ') + '\n';   // sliced, never retyped: a fourth copy of the number is the bug
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

/* NOTHING TO SHOW MEANS NOTHING RENDERED, which is the case MOST claims are in.
   With no parent, no parts and no related claims this printed a heading, a
   caption asserting relations had been read from the chain, and a paragraph
   about what relations do not do — three pieces of furniture around an absence,
   and a caption that read as a claim something was found.
   Asserted with a claim that has no relations at all AND an empty chain answer,
   because those are two different sources of nothing and either one alone would
   have let the other regress. */
const bare = i => null;
const noRelId = (() => {
  const rel = DEMO.relations.orem;
  for(const k of Object.keys(DEMO.claims)){
    if(!k.startsWith("orem/")) continue;
    const id = +k.split("/")[1];
    if(!rel.some(r => r.from === id || r.to === id)) return id;
  }
  return null;
})();
ok("a claim with no relations exists in the fixture to test with", noRelId !== null);
ok("...and its section is empty, not a heading over nothing",
   associationSection("orem", noRelId, demoLookup) === "");
ok("...also with an empty chain answer rather than none",
   associationSection("orem", noRelId, demoLookup, []) === "");
ok("...and a claim that HAS relations still renders", h9.includes("Where this claim sits"));
// The id-only fallback: a related claim outside the loaded window is marked for
// the filler rather than explained in terms of this page's pagination.
ok("a title the window lacks is marked for fetching, not narrated",
   associationSection("orem", 9, bare).includes("data-needtitle")
   && !associationSection("orem", 9, bare).includes("not in the rendered docket window"));
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
/* "· round N" ONLY ONCE A ROUND HAS FAILED. Asserted as the PAIR, because the
   rule is a conditional and only the pair can catch it being inverted or
   dropped: a first-round dispute names no number, a later one still does. The
   fixtures above are all round:1, so every assertion in this file passed both
   before and after the change — this is the arm that was missing. */
const L0 = resolutionLadder(Object.assign({}, d3l, {round:0}), NOW);
ok("a first-round dispute names no round number",
   L0.includes("dispute opened") && !/dispute opened \u00b7 round/.test(L0)
   && L0.includes("vote closes") && !/vote closes \u00b7 round/.test(L0));
ok("...and says nothing about failed rounds either", !L0.includes("failed round"));
ok("...while a second round still says which round it is",
   L3.includes("vote closes \u00b7 round 2") && L3.includes("1 failed round"));
const L0n = resolutionLadder(Object.assign({}, d3n, {round:0}), NOW);
ok("the unexposed-close note takes a subject when it has no number",
   L0n.includes("the vote is running") && !/round 1 is voting/.test(L0n));
ok("...and keeps the number on a later round", L3n.includes("round 2 is voting"));

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

  /* THE CLOSE IS READ, NOT ESTIMATED. ClaimTimeline publishes
     `voteclose:<unix>:<height>` — the moment the governor gates on — and the row
     must use it. The old code derived the date from a height at an assumed
     cadence, and that projection is what put this row five years out on a claim
     answered in 2021. A published close is exact, so it carries no ≈. */
  {
    const exact = Object.assign({}, tl, {voteclose:{t:T0+123456, h:9999}});
    const E = resolutionLadder(D, NOW, exact);
    ok("dated ladder: a published close is used verbatim, not projected",
       E.includes(stampDate(T0+123456)));
    ok("dated ladder: ...and is not marked as an estimate",
       !/≈[^<]*vote closes/.test(E) && E.includes("vote closes · round 3"));

    /* AND THE ESTIMATE SURVIVES for a dispute opened before the stamps, where a
       height is genuinely all there is. Dropping the fallback would blank the
       row for every pre-upgrade claim. */
    const noStamp = Object.assign({}, tl); delete noStamp.voteclose;
    const N = resolutionLadder(D, NOW, noStamp);
    ok("dated ladder: with no published close the row still appears, estimated",
       N.includes("vote closes · round 3"));
  }
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
  /* THE DISPUTE ITSELF IS AN EVENT. The ladder had a row for rounds that FAILED
     and none for the one that is running, so a claim in its first round read
     "opened, answered, now, vote closes" — while the notice directly above it
     said a dispute was under way. A reader had to infer the dispute from the
     existence of a vote, on the surface whose whole job is saying what
     happened. Dateless for the same reason the failed rounds are. */
  ok("dated ladder: the dispute has a rung of its own",
     L.includes("dispute opened · round 3"));
  /* DATELESS ONLY WHEN THE CHAIN IS. This tl carries no `dispute` key, which is
     a round opened before ClaimTimeline published one — there the em-dash is the
     honest answer. The stamped case is below, and it is the common one now. */
  ok("dated ladder: ...dateless when the chain published no dispute stamp",
     /dispute opened · round 3<\/div><div class="dt"[^>]*>—<\/div>/.test(L));
  {
    const stamped = Object.assign({}, tl, {dispute:{t:T0-500000, h:2500}});
    const S = resolutionLadder(D, NOW, stamped);
    ok("dated ladder: a published dispute stamp is drawn as a date, not an em-dash",
       S.includes(stampDate(T0-500000))
       && !/dispute opened · round 3<\/div><div class="dt"[^>]*>—<\/div>/.test(S));
    /* A DATED ROW SORTS BY ITS DATE, which is the whole point of dating it —
       so it lands between the events it happened between, not in the pseudo-time
       slot the dateless row occupies just before "now". Asserting the old
       ordering here would be asserting that the date is ignored. */
    ok("dated ladder: ...and it sorts by that date, after the answer",
       S.indexOf("answered") < S.indexOf("dispute opened")
       && S.indexOf("dispute opened") < S.indexOf(">now<"));
  }
  ok("dated ladder: ...after the rounds that failed, before now",
     L.indexOf("failed rounds") < L.indexOf("dispute opened")
     && L.indexOf("dispute opened") < L.indexOf(">now<"));
  // A FIRST ROUND IS THE CASE THAT WAS BARE: no failed rounds to imply a
  // dispute, so the rung is the only thing that names one.
  // WHAT THESE TWO ARE ABOUT IS THE ROW, NOT THE NUMBER. They read
  // "dispute opened \u00b7 round 1" until the number was dropped from a first
  // round — d.round is 0 for the whole of one, so that suffix said "1" on nearly
  // every claim that ever showed the row. The intent above is unchanged and the
  // absent number is asserted beside it, so neither arm can pass on a row that
  // has gone missing OR on the number coming back.
  {
    const first = Object.assign({}, d3l, {round:0, phase:"disputed", voteEndsAt:NOW+70000});
    const F = resolutionLadder(first, NOW, tl);
    ok("dated ladder: a first-round dispute is named too",
       F.includes("dispute opened") && !/dispute opened \u00b7 round/.test(F)
       && !F.includes("failed round"));
    // and the flat branch, which is a separate renderer and drifts if unasked
    const G = resolutionLadder(first, NOW, null);
    ok("flat ladder: it names the dispute as well",
       G.includes("dispute opened") && !/dispute opened \u00b7 round/.test(G));
    // Neither names one when there is no dispute to name.
    const calm = Object.assign({}, d3l, {round:0, phase:"answered", voteEndsAt:null});
    ok("neither ladder invents a dispute on a claim that has none",
       !resolutionLadder(calm, NOW, tl).includes("dispute opened")
       && !resolutionLadder(calm, NOW, null).includes("dispute opened"));
  }
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

/* A CHAIN-SOURCED ROW ARRIVES WITH ITS SENTENCE, and for a while it did not.
   The titles lookup was gated on "local curation has relations", which was the
   only thing that could produce a row when it was written. Once the chain began
   storing associations that gate stopped covering the common case: on a court
   read live with no curation loaded, every row rendered with an empty title and
   was then repaired one at a time by fillAssocTitles, two reads per row. Between
   the render and the repair the section is a heading, a caption and a couple of
   rows with the sentence missing — reported as the section being "empty".
   Pinned on both sides: what a row looks like with a lookup and without one, and
   that the gate the route applies asks whether there are ROWS, not whose they
   are. */
ok("with a lookup, a row carries its title and needs no repair", (()=>{
  const r = assocRow("covid", 18, "supported by this",
    () => ({title:"The Proximal Origin paper was drafted at the prompting of the director of NIAID.",
            statusText:"open"}));
  return r.includes("The Proximal Origin paper was drafted") && !r.includes("data-needtitle");
})());
ok("...and without one it is marked for repair rather than guessed at", (()=>{
  const r = assocRow("covid", 18, "supported by this", null);
  return r.includes('data-needtitle="18"') && !/<span class="t"[^>]*>[^<]/.test(r);
})());
ok("the route builds that lookup for chain rows too, not only curated ones",
   src.includes("const needTitles = (cu && cu.relations.length) || (Array.isArray(chainAssocs) && chainAssocs.length)"));
ok("...and the lookup is built after the chain read it depends on",
   src.indexOf("const chainAssocs = await chainAssociations") < src.indexOf("const needTitles ="));
ok("...with the repair pass kept for ids the docket read cannot answer",
   src.includes("fillAssocTitles(slug);"));

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
