// B8 harness: associationSection + resolutionLadder + demo-data ripples.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice, fn } = require("./srcslice");
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
code += 'const ICN_FOLDER="<svg/>";\n';   // stubbed as folders_test does: the row needs the mark to exist, not to be drawn
// verdictSentence dresses the related row's title now — the side rides the
// sentence here as it does on the claim page and the map, so the builder has to
// be in scope alongside the row that calls it.
code += fn('verdictSentence');
// verdictSentence delegates the oval to sideOval now, and the row builders ask
// rowSide whether there is one — both are new and neither is inside the region
// any existing anchor already cut.
code += fn('sideOval');
code += fn('rowSide');
code += slice('function assocRow(', '/* ======================= local curation');
code += 'var BLOCK_SECS=' + src.match(/const BLOCK_SECS\s*=\s*(\d+)/)[1] + ';\n';
code += slice('const MON=', 'function resolutionLadder(').replace(/^const MON=/m,'var MON=');
code += slice('function resolutionLadder(', 'function resolutionSection');
code += slice('function demoCensus(', 'function courtRecordPanel');
code += slice('function folderCount(', 'function folderMeta');
eval(code);


/* A GROUP HEADING, WITH OR WITHOUT ITS NOTE. These were pinned as ">Part of<",
   which stopped matching the moment a heading could carry a count beside its
   label. The label is what matters; whether a note rides with it is the other
   assertions' business. */
const headAt = (h, label) => h.indexOf(`>${label}</div>`) >= 0
  ? h.indexOf(`>${label}</div>`) : h.indexOf(`>${label} <span class="count">`);
const hasHead = (h, label) => headAt(h, label) >= 0;

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
// The section no longer wears a title of its own — the group headings are it.
ok("#9: section renders", hasHead(h9, "Related") || hasHead(h9, "Part of") || hasHead(h9, "Rests on"));
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
ok("...and a claim that HAS relations still renders", hasHead(h9, "Related") || hasHead(h9, "Part of"));
// The id-only fallback: a related claim outside the loaded window is marked for
// the filler rather than explained in terms of this page's pagination.
ok("a title the window lacks is marked for fetching, not narrated",
   associationSection("orem", 9, bare).includes("data-needtitle")
   && !associationSection("orem", 9, bare).includes("not in the rendered docket window"));
ok("#9: rests on 3, 1 settled", h9.includes("1 of 3 parts settled"));
ok("#9: undecided banner", h9.includes("2 of 3 parts are still undecided — any verdict here is reached without them"));
ok("#9: children rows 3/4/7 as 'one part'", ["/3","/4","/7"].every(x=>h9.includes(`#/c/orem${x}`)) && (h9.match(/one part/g)||[]).length===3);
/* NAMING THE OBJECT, on both halves. "supports" alone did not say which way —
   asked of covid/19 — while the outbound half already read "supported by this".
   Pinned as the whole predicate, so dropping the object fails here rather than
   passing on a substring of it. */
ok("#9: #6 supports this (incoming)", h9.includes(">supports this<") && h9.includes("#/c/orem/6"));
ok("#9: fineprint", h9.includes("Curation, not mechanics: relations move no stake, no bond, no bar, no verdict"));
ok("#9: no yes% or sparkline in rows", !h9.includes("YES now") && !h9.includes("spark"));

// ---- #3: part-of line + contradicts (incoming) ----
const h3 = associationSection("orem", 3, demoLookup);
// The parent is a ROW like every other relation, on the containment axis with
// "Rests on" rather than in the association graph under "Related". It was a bare
// paragraph: no chip, and no status pill on the whole it is a part of.
ok("#3: Part of subsection", hasHead(h3, "Part of"));
// "the whole" asserted the parent was the top of the tree. Containment is a
// tree and the design runs three levels, so a parent is usually a part too.
ok("#3: parent is a row, chipped by its relation", /assocrow[^]*?#\/c\/orem\/9/.test(h3) && h3.includes(">contains this<"));
ok("#3: chip does not claim to be the top of the tree", !h3.includes(">the whole<"));
ok("#3: parent row carries the whole's status", h3.slice(headAt(h3, "Part of")).slice(0,700).includes("pill"));
ok("#3: parent is NOT filed under Related", headAt(h3, "Part of") < (hasHead(h3, "Related")? headAt(h3, "Related") : Infinity));
ok("#3: #11 contradicts this", h3.includes(">contradicts this<") && h3.includes("#/c/orem/11"));
ok("#3: no rests-on subsection", !h3.includes("Rests on"));

// ---- #5: superseded (incoming supersedes) ----
const h5 = associationSection("orem", 5, demoLookup);
ok("#5: #10 supersedes this", h5.includes(">supersedes this<") && h5.includes("#/c/orem/10"));
/* Both directions on one page must not both read as the bare verb — that is the
   ambiguity, not the wording of either one alone. */
ok("no inbound chip is left without its object", (()=>{
  const all = [h9, h3, h5].join("");
  return !/>(supports|contradicts|supersedes)<\/span>/.test(all);
})());

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
/* THE SETTLED ROW WEARS THE OVAL NOW, not a phase pill: these rows carry the
   related claim's TITLE, so the verdict rides the sentence exactly as it does on
   the claim page and the map. The precedence this assertion was written for is
   unchanged and still pinned — #4's answer was NO and its verdict YES, and YES
   is what the oval says — and the pill's ABSENCE is asserted beside it, since
   dropping the pill is the change and a row carrying both would be the bug.
   #3 is in dispute and wears the SAME OVAL, questioned. It carried the phase
   pill — "YES?" in the dispute colour, off in the right-hand cluster — while the
   same claim's own page put the oval on its title. Reported as: it shows a
   golden box, it should be the outlined oval, and closer to the title.
   The relation pill stays on both: that is the edge, not the phase, and nothing
   else on the row says it. */
ok("#9 rows: #4 wears the verdict's oval, #3 wears it questioned",
   /vtag y">YES</.test(h9) && !h9.includes(">settled YES<")
   && h9.includes('<span class="vq"')
   /* The DISPUTE pill specifically, not the escrow class: a provisional row in
      this same section wears escrow too and rightly keeps its phase pill — it
      has no oval to carry the fact. Banning the class outright failed here and
      would have been the wrong pin anyway. */
   && !/<span class="pill escrow">(YES|NO)\?</.test(h9));
ok("...and the contested mark follows the oval, not the row's chip cluster", (()=>{
  const lk = id => { const d = DEMO.claims["orem/"+id]; return d? {title:d.title, statusText:statusText(d)} : null; };
  const r = assocRow("orem", 3, "contradicts this", lk);
  const oval = r.indexOf('sidetag vtag'), q = r.indexOf('class="vq"'), rt = r.indexOf('class="rt"');
  return oval >= 0 && q > oval && q < rt;
})());
/* THE MARK'S COLOUR TRAVELS WITH THE OVAL. .vtag.y is deliberately unscoped —
   "COLOUR IS NOT SCOPED, sizing is" — because the same answer must look the same
   in the heading and in a row. The question mark now appears in both too, so its
   colour and weight have to leave .page-h with it; left scoped, a contested row
   renders the mark in the row's ink and the two surfaces disagree.
   Asserted on the stylesheet because it is a scoping fact, which no rendered
   string can show: the markup is identical either way. */
ok("the contested mark is coloured outside the heading's scope",
   /^\.vq\{[^}]*color:var\(--muted\)/m.test(src)
   && !/^\.page-h \.vq\{[^}]*color:/m.test(src));

/* NOT STRUCK, even on a NO: the strike says "no longer accurate", which is a
   verdict, and a dispute has not reached one. */
ok("...and a contested NO is not struck through", (()=>{
  const r = assocRow("orem", 3, "x", () => ({title:"t", statusText:"disputed NO — a sealed vote is deciding"}));
  return r.includes('vtag n">NO<') && r.includes('class="vq"') && !r.includes("<s>");
})());

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
/* A ROW WITH NO CHIP MUST NOT KEEP THE CHIP'S COLUMN. The court's policing rows
   stopped emitting a status pill when the verdict moved onto their sentence, and
   the 268px track stayed — measured on /c/covid: two children in a three-track
   row, the title squeezed into 196px of a 584px row with 268px empty beside it,
   rows 162px tall. Reported as squished. The docket made the identical mistake
   when its own pill left.
   THE DEMO FIXTURE CANNOT CATCH THIS: every assocrow it renders has a chip, so a
   browser check on the sample court passes either way. Asserted on the source,
   where the pairing is visible — the class is derived from the cell so the two
   cannot disagree, and that derivation is what is pinned. */
ok("a chip-less policing row drops the chip's column",
   src.includes('.docket a.crow.assocrow.nochip{grid-template-columns:52px minmax(0,1fr)}'));
ok("...and the class is taken from the cell, not from a second reading of it",
   (src.match(/const chip = byId\[r\.id\] && !sd\? statusPill\(byId\[r\.id\]\.statusText\) : "";/g)||[]).length === 2
   && (src.match(/assocrow\$\{chip\? "" : " nochip"\}/g)||[]).length === 2);
ok("...so a row for a claim outside the window loses it too", (()=>{
  // byId misses the id: no side to show AND no status to draw, so no third cell.
  // Deriving the class from `sd` alone would have left this row squeezed.
  return !/assocrow\$\{sd\?/.test(src);
})());

/* THE CLAIM ROW'S ID TRACK. It was 52px, sized for the four-column template the
   row stopped using when the pill moved to the meta line; "#19" is 24px of mono
   and the assocrow already narrows to 44 at width. Measured on the sample court
   at 1280px: the title track goes 412px to 420px, the tallest row 141px to
   119px, and the docket's total height 1258px to 1211px.
   A NARROW-WIDTH RULE WAS TRIED AND DROPPED, which is worth recording so it is
   not written again: collapsing the third track at 820px and moving the
   percentage onto the meta line changed the title cell by 12px and the total
   height by nothing, because at 390px that cell is already 160px on its own
   line. The absence is deliberate. */
ok("the claim row's id track is sized for a claim id", 
   src.includes(".docket a.crow.claimrow{grid-template-columns:44px minmax(0,1fr) 64px}"));
ok("...and no narrow-width override was left behind for it",
   !/@media[^{]*\{[^}]*\.docket a\.crow\.claimrow\{/.test(src));
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


/* WHERE THIS CLAIM SITS INCLUDES THE SHELF IT IS ON. Asked as: "where this
   claim sits... should show its parent folder?" It did not, and on a chain court
   nothing else on the page did either — the "filed under" chip beside the title
   is built from curation, so a court read live from the chain has none.
   Kept as its own row rather than folded into "Part of": COURTS_STRUCTURE.md §5
   names two edges that must not be merged, containment between claims and the
   argument graph, and a folder is neither — it is moderator filing with no
   economic weight. */
ok("a folder alone renders the section", (()=>{
  const h = associationSection("covid", 11, null, null, [{fid:4, name:"Proximal Origin"}]);
  return hasHead(h, "Filed in") && h.includes("Proximal Origin")
      && h.includes('href="#/c/covid/f/4"');
})());
ok("...and is captioned as filing, not as relations the chain does not store", (()=>{
  const h = associationSection("covid", 11, null, null, [{fid:4, name:"Proximal Origin"}]);
  // The caption goes through esc(), so the apostrophe arrives as &#39; — match
  // either form rather than pinning the entity, which is an encoding detail.
  return /filed by this court(&#39;|')s moderators/.test(h)
      && !h.includes("the chain stores no relations");
})());
/* EACH NOTE RIDES THE GROUP IT DESCRIBES. There used to be one caption over
   everything, on a "Where this claim sits" heading that had nothing of its own
   beneath it — a title, a caption, then immediately "Filed in". Reported as an
   empty redundant thing, and as verbose.
   Splitting the note is what removes the contradiction rather than papering
   over it: the folder note cannot sit above a relations row, because it is
   attached to the folder row's own heading. */
ok("the folder note rides Filed in, not a heading above everything", (()=>{
  const h = associationSection("covid", 18, null, [[11,"supports"]],
                               [{fid:4, name:"Proximal Origin"}]);
  const filed = h.slice(headAt(h,"Filed in"), headAt(h,"Related"));
  return /filed by this court(&#39;|')s moderators/.test(filed)
      && !/relations read from the chain/.test(filed);
})());
ok("...and the relations note rides Related", (()=>{
  const h = associationSection("covid", 18, null, [[11,"supports"]],
                               [{fid:4, name:"Proximal Origin"}]);
  return /relations read from the chain/.test(h.slice(headAt(h,"Related")));
})());
ok("...each note appearing once, not once per group", (()=>{
  // TWO claim-row groups, which is what makes this bite: with only "Related"
  // present a note emitted per group is indistinguishable from one emitted once.
  // Claim 3 carries a curation parent, so "Part of" renders above "Related".
  const h = associationSection("orem", 3, demoLookup, [[11,"supports"]],
                               [{fid:4, name:"Proximal Origin"}]);
  const groups = ["Part of","Related"].filter(l=>hasHead(h,l));
  return groups.length === 2
      && (h.match(/relations read from the chain/g)||[]).length === 1
      && (h.match(/filed by this court/g)||[]).length === 1;
})());
/* AND THE GROUPS STAY APART. With the section title gone the first heading sits
   flush at the top, so the gap that separates one group from the next has to
   come from the headings themselves — one rule, or they drift. */
ok("the first group heading is flush, the rest are spaced", (()=>{
  const h = associationSection("orem", 3, demoLookup, [[11,"supports"]],
                               [{fid:4, name:"Proximal Origin"}]);
  const mts = [...h.matchAll(/class="sec-h" style="margin-top:(\d+)px"/g)].map(m=>+m[1]);
  return mts.length >= 3 && mts[0] === 0 && mts.slice(1).every(v=>v === 14);
})());
/* THE SECTION HAS NO TITLE OF ITS OWN, and that is the fix, not a side effect.
   "Where this claim sits" sat above the group headings with nothing beneath it
   before the first of them. */
ok("no heading sits above the groups with nothing under it", (()=>{
  const h = associationSection("covid", 18, null, [[11,"supports"]],
                               [{fid:4, name:"Proximal Origin"}]);
  // The section opens straight onto a group heading.
  return !h.includes("Where this claim sits")
      && /^<section[^>]*><div class="sec-h"[^>]*>Filed in /.test(h);
})());
ok("...and a claim with only relations is captioned only for them", (()=>{
  const h = associationSection("covid", 18, null, [[11,"supports"]], []);
  const cap = (h.match(/<span class="count">(.*?)<\/span>/)||[])[1] || "";
  return /relations read from the chain/.test(cap) && !/filed by/.test(cap);
})());
/* "Filed in" over "filed here" said it twice. The other groups' chips vary and
   so carry information; a folder's would be constant. */
/* THE CHIP CAME BACK, EARNING THE SLOT THIS TIME. "filed here" was the same two
   words on every row under a heading that had just said them. A count varies, so
   it says what the heading cannot, and answers the question the row invites —
   how much else is on this shelf — without a page load. Asked for directly. */
ok("a folder row states how many claims the folder holds", (()=>{
  const h = associationSection("covid", 11, null, null,
    [{fid:3, name:"Gain-of-function funding", count:3}]);
  return h.includes(">3 claims</span>") && h.includes("Gain-of-function funding");
})());
ok("...singular when it holds one", (()=>{
  const h = associationSection("covid", 11, null, null, [{fid:4, name:"Solo", count:1}]);
  return h.includes(">1 claim</span>") && !h.includes("1 claims");
})());
/* A folder holding this claim can never truthfully hold zero, so a zero here
   would be a lie about the shelf rather than an admission that the read failed.
   Omitted in both cases. */
ok("...and omitted, not zeroed, when the count is unknown", (()=>{
  const unread = associationSection("covid", 11, null, null, [{fid:4, name:"Unread", count:null}]);
  const zero   = associationSection("covid", 11, null, null, [{fid:4, name:"Zero", count:0}]);
  return !/\bclaims?<\/span>/.test(unread) && !/\bclaims?<\/span>/.test(zero)
      && unread.includes("Unread") && zero.includes("Zero");
})());
ok("the folder row carries no chip repeating its own heading", (()=>{
  const h = associationSection("covid", 11, null, null, [{fid:4, name:"Proximal Origin"}]);
  return hasHead(h, "Filed in") && !h.includes("filed here");
})());
ok("...and sits above the claim rows, being the coarser fact", (()=>{
  const h = associationSection("covid", 11, null, [[18,"supported by this"]],
                               [{fid:4, name:"Proximal Origin"}]);
  return headAt(h, "Filed in") < headAt(h, "Related");
})());
ok("a cross-filed claim lists every folder it is in", (()=>{
  const h = associationSection("covid", 11, null, null,
    [{fid:4, name:"Proximal Origin"}, {fid:1, name:"Origins"}]);
  return (h.match(/class="crow assocrow"/g)||[]).length === 2;
})());
ok("no folder, no row — and no section when there is nothing else either", (()=>{
  return associationSection("covid", 11, null, null, []) === ""
      && associationSection("covid", 11, null, null, null) === "";
})());
ok("a folder with no readable name is not rendered as a blank shelf", (()=>{
  return associationSection("covid", 11, null, null, [{fid:4, name:""}]) === "";
})());
/* A source match would not have held this: the same safeInline(f.name) call
   appears in folderRowHtml too, so grepping for it passes even if THIS row
   drops it. Rendered and inspected instead. */
ok("the folder name is escaped, being moderator-supplied text", (()=>{
  const h = associationSection("covid", 11, null, null,
    [{fid:4, name:'<img src=x onerror=alert(1)>Origins'}]);
  return !h.includes("<img src=x") && h.includes("Origins");
})());


/* NO SURFACE STILL SAYS "settled YES" IN A PILL. Reported after four surfaces
   had already moved: /c/covid's policing lists were still doing it, and so were
   the two sample dockets and the holdings table. They were missed one at a time
   because each surface decided for itself what a settled row shows.
   THE SOURCE IS THE SUBJECT HERE, deliberately. A rendered check can only cover
   the rows a fixture happens to produce, and "the ones nobody thought of" is
   exactly the set that was wrong. Every call is read instead, and each must be
   guarded by the shared question rather than passing the status text straight
   in. */
ok("every statusPill call is gated on there being no side to show", (()=>{
  const calls = [...src.matchAll(/statusPill\(/g)].map(m => {
    const line = src.slice(src.lastIndexOf("\n", m.index) + 1, src.indexOf("\n", m.index));
    return line.trim();
  }).filter(l => !l.startsWith("function statusPill"));
  // Every remaining call sits behind a "no side" test, or is the /needs ballot
  // row, which is handed a literal phase and has no claim record to read a side
  // from at all.
  const guarded = l => /!sd\?|!side\?|dSide\?|side \? ""|rowSide\(/.test(l)
                    || l.includes('statusPill("disputed")');
  const bad = calls.filter(l => !guarded(l));
  if(bad.length) console.log("   unguarded:", bad);
  return calls.length >= 6 && bad.length === 0;
})());
/* The oval and the pill are alternatives, never both: a row wearing the verdict
   on its sentence AND a pill repeating it is the state this was fixing. */
ok("a settled row shows the oval and drops the pill", (()=>{
  const settled = {title:"t", statusText:"settled NO — every stake withdraws 1×"};
  const r = assocRow("orem", 4, "x", () => settled);
  return r.includes('vtag n">NO<') && !r.includes('class="pill good"') && !/>settled NO</.test(r);
})());
ok("...and a row with no readable side keeps its pill", (()=>{
  const bare = {title:"t", statusText:"settled — every stake withdraws 1×"};
  const r = assocRow("orem", 4, "x", () => bare);
  return !r.includes("vtag") && r.includes("pill");
})());
/* rowSide ANSWERS FOR SETTLED ONLY, and that is load-bearing now that a disputed
   status names its side too: "disputed YES" has a readable side, and a row that
   took the oval from it would drop its pill and show a bare YES — the verdict's
   mark on a claim that has no verdict, with the question mark gone. */
ok("rowSide answers for a settled claim and nothing else", (()=>{
  return rowSide("settled YES — every stake withdraws 1×") === "YES"
      && rowSide("settled NO — every stake withdraws 1×") === "NO"
      && rowSide("disputed YES — a sealed vote is deciding") === ""
      && rowSide("provisional verdict YES — reopenable") === ""
      && rowSide("open — stake YES or NO") === "";
})());
ok("...so a disputed row keeps its questioned pill rather than a bare oval", (()=>{
  const r = assocRow("orem", 4, "x",
    () => ({title:"t", statusText:"disputed YES — a sealed vote is deciding"}));
  // It wears the oval THROUGH the contested path, which carries the mark with it.
  return r.includes('class="vq"') && r.includes('vtag y">YES<');
})());
/* sideOval is what makes the table cell possible — a column cannot go blank on
   settled rows the way a row-end can — so it must build the same oval the
   sentence does, not a second span that drifts. */
ok("the oval in a cell is the same oval as in a sentence", (()=>{
  return verdictSentence("t", "YES").includes(sideOval("YES"))
      && verdictSentence("t", "NO").includes(sideOval("NO"));
})());

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
