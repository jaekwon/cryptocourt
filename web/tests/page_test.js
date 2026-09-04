// B9 harness: pager math, hash-param parsing shape, demo list order,
// demoRender cap fidelity, listClaimsPage window math (offline parts).
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice } = require("./srcslice");
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo' };
global.isLive = ()=> CFG.mode==='live';
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = Number(NOWm[1].replace(/_/g,''));
global.BLOCK_SECS = 5;

let code = 'var QP={};\n';
code += slice('function esc(', '\n');
code += 'function unesc(x){ return String(x); }\n';
code += slice('function fmtN(', 'function ugnot(');
// listClaims now carries the instantaneous ratio on each row, so the docket
// cell can show a number when the three-point spark cannot be drawn.
code += slice('function pctYes(', '/* A per-claim sparkline');
code += 'var NOW='+global.NOW+';\n';
// Round 28 split the literal: DEMO_CHAIN (generated) + DEMO_OVERLAY
// (hand-written: desc, nested folders, relations, voteEndsAt), joined by
// mergeDemo. Build the merged object the way the page does.
code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED').replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED').replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
// statusText names the verdict side now, so it needs sideName.
code += slice('const sideName =', '\n').replace('const sideName =','var sideName =') + '\n';
code += slice('function statusText(', '\n/* =');
code += 'function claimSeries(){ return [50,50,50]; }\n';
code += slice('const PAGE_N', 'function errorView').replace('const PAGE_N','var PAGE_N');
code += slice('async function listCourts(', 'const demoCourt').replace('async function listCourts','async function listCourtsX');
code += 'const demoCourt = slug => Object.hasOwn(DEMO.courts, slug)? DEMO.courts[slug] : null;\n';
code += slice('async function listClaims(', 'async function claimDetail').split('/* A deeper docket window')[0];
code += slice('function demoRender(', '/* ============================ boot');
// pageOf/pagerHtml/pageSlice come with the PAGE_N slice? PAGE_N slice spans to listClaimsPage — includes them.
code = "var demoStrips = slug => ({strip:[], pending:[]});\n" + code;
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

(async ()=>{
  // pager math
  QP={};
  // D4: one-window listings now STATE their order (caption always; nav only when actionable)
  const pg1 = pagerHtml("/c/orem",1,11,11,"claims");
  ok("one window states its order", pg1.includes("all 11 claims · newest first"));
  ok("one window has no nav pills", !pg1.includes("older ›") && !pg1.includes("‹ newer"));
  ok("empty ledger renders nothing", pagerHtml("/c/orem",1,0,0,"claims")==="");
  ok("singular label at total 1", pagerHtml("/",1,1,1,"courts","ranked by GNOT burned").includes("all 1 court · ranked by GNOT burned"));
  // "ctv" rather than the retired "yes": a test that carries a sort key the app
  // no longer accepts still passes, and stops describing anything.
  QP={sort:"ctv"};
  const pgS = pagerHtml("/c/orem", 2, 25, 214, "claims");
  ok("links carry the active sort", pgS.includes('href="#/c/orem?sort=ctv"') && (pgS.includes("sort=ctv&amp;p=3") || pgS.includes("p=3&amp;sort=ctv")));
  QP={at:"resolution",focus:"7"};
  const pgX = pagerHtml("/c/orem", 2, 25, 214, "claims");
  ok("links never carry at/focus", !pgX.includes("at=") && !pgX.includes("focus="));
  QP={};
  const pgC = pagerHtml("/c/orem", 1, 25, 214, "claims", undefined, '<span class="schips">CHIPS</span>');
  ok("chips render inside the pager", pgC.includes('<span class="schips">CHIPS</span>'));
  QP={p:"2"};
  ok("pageOf parses ?p=2", pageOf()===2);
  QP={p:"0"}; ok("pageOf clamps 0→1", pageOf()===1);
  QP={p:"x"}; ok("pageOf clamps junk→1", pageOf()===1);
  QP={};
  const pg = pagerHtml("/c/orem", 2, 25, 214, "claims");
  ok("caption 26–50 of 214", pg.includes("showing 26–50 of 214 claims · newest first"));
  ok("newer chip links p1 (no ?p)", pg.includes('href="#/c/orem"'));
  ok("older chip links p3", pg.includes('href="#/c/orem?p=3"'));
  const pgLast = pagerHtml("/c/orem", 9, 14, 214, "claims");
  ok("last page: older chip disabled", pgLast.includes('class="pill void off pnav">older ›'));
  const pgCur = pagerHtml("/c/orem/f/0", 1, 25, 30, "claims", "curated order");
  ok("curated order caption", pgCur.includes("curated order"));
  // pageSlice
  const L=[...Array(60).keys()];
  ok("pageSlice window 2 = 25..49", pageSlice(L,2)[0]===25 && pageSlice(L,2).length===25);
  ok("pageSlice tail short", pageSlice(L,3).length===10);

  // demo list order: newest first
  const cl = await listClaims("orem");
  ok("demo docket newest-first (11 first)", cl[0].id===11 && cl[cl.length-1].id===1);
  ok("demo docket 11 rows", cl.length===11);

  // footer parse: synthesize a live-shaped md through the regexes
  CFG.mode='live';
  global.qrender = async ()=> "# Orem\n\n## Claims\n\n- [T](/r/kourt/kourtv2:orem/60) — open — stake YES or NO\n\n…and 35 older; open any by id\n";
  const clL = await listClaims("orem");
  ok("live footer parsed: more=35", clL.more===35 && clL.length===1);
  global.qrender = async ()=> "## Featured\n\n- [A](/r/kourt/kourtv2:aaa) · AAA — 3 claims\n\n…and 12 more\n\n## Courts\n\n- [B](/r/kourt/kourtv2:bbb) · BBB — 5 claims\n";
  const co = await listCourtsX();
  ok("featured footer attributed to moreFeatured, never listed", co.moreFeatured===12 && co.more===undefined && co.length===2);
  CFG.mode='demo';

  // demoRender cap+footer fidelity (orem 11 → no footer; synthetic 60 → footer)
  const md = demoRender("orem");
  ok("demoRender: newest-first docket", md.indexOf("kourtv2:orem/11") < md.indexOf("kourtv2:orem/1\)") || md.indexOf("orem/11") < md.indexOf("orem/1)"));
  ok("demoRender: no footer at 11 claims", !md.includes("older; open any by id"));
  DEMO.courts.orem.claims = Array.from({length:60},(_,i)=>i+1);
  for(let i=12;i<=60;i++) DEMO.claims["orem/"+i]=DEMO.claims["orem/1"];
  const md60 = demoRender("orem");
  ok("demoRender: caps at 50 + footer at 60 claims", md60.includes("…and 10 older; open any by id") && (md60.split("## Needs review")[0].split("[Moderation log]")[0].match(/kourtv2:orem\/\d/g)||[]).length===50);


  // F5/F7 fix assertions
  const srcF = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
  ok("F6: hidden filter fails closed", srcF.includes('HiddenFromListing(${s2},${i})`).catch(()=>true)'));
  ok("F2: docket p1 windows by id", srcF.includes("parsed.filter(c=>c.id>=lo1)"));
  ok("F1: deep directory pages use ListedCourtsBy burn", srcF.includes('ListedCourtsBy("burn"'));
  ok("F4: directory order label", srcF.includes('"ranked by GNOT burned"'));
  QP={};
  const pgOver = pagerHtml("/c/orem", 3, 0, 30, "claims");
  ok("F7: past-the-end caption", pgOver.includes("page 3 is past the end — 30 claims in all"));

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
