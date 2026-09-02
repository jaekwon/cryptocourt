// B3 harness: demoCensus + courtRecordPanel + scope line, from the live file.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice } = require("./srcslice");
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo', gnoweb:'https://gno.land', rpc:'http://x', chainid:'dev' };
global.PKG = 'gno.land/r/kourt/kourtv2';
global.isLive = ()=> CFG.mode==='live';
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = NOWm? Number(NOWm[1].replace(/_/g,'')) : 4800000;

let code = '';
code += slice('function esc(', '\n');
code += slice('function fmtN(', 'function ugnot(');
code += 'var NOW='+global.NOW+';\n';
code += 'var DEMO=' + slice('{\n  courts:{', 'const DEMO_ME').replace(/;\s*$/,'') + ';\n';
// Wait: DEMO literal starts "const DEMO = {" — grab from that anchor instead:
code = code.replace(/var DEMO=[\s\S]*$/, '');
// Round 28 split the literal: DEMO_CHAIN (generated) + DEMO_OVERLAY
// (hand-written: desc, nested folders, relations, voteEndsAt), joined by
// mergeDemo. Build the merged object the way the page does.
code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED').replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED').replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
code += slice('const RECORD_K', 'async function fillCourtRecord');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// judge's orem census: undis 0 / vote 1 (1 overturned) / nodec 1 / unans 1 / live 5 / failed 6
const cen = demoCensus("orem");
ok("orem undis 0", cen.undis===0);
ok("orem vote 1", cen.vote===1);
ok("orem overturned 1", cen.ov===1);
ok("orem nodec 1", cen.nodec===1);
ok("orem unans 1", cen.unans===1);
ok("orem live 8 (3 new open claims)", cen.live===8);
ok("orem failed 6 (3+2+1)", cen.failed===6);
ok("census sums to 11", cen.undis+cen.vote+cen.nodec+cen.unans+cen.live===11);

const cl = demoCensus("ledger");
ok("ledger live 3 (provisional + the D6-4 disputed exemplar), 1 failed round", cl.live===3 && cl.vote===0 && cl.failed===1);

// panel render (demo)
const s = {claims:11, burned:7020070389605, minted:118491100000, price:118};
const html = courtRecordPanel("orem", s);
ok("panel: h4 Court record", html.includes("<h4>Court record</h4>"));
ok("panel: scope of 11", html.includes("of this court's 11 claims"));
ok("panel: burned 7,020,070 GNOT", html.includes("7,020,070 GNOT"));
ok("panel: keyless sub", html.includes("destroyed at a keyless address, not held; nothing redeems it"));
ok("panel: overturn note", html.includes("1 overturned the answer"));
ok("panel: verdict note", html.includes("· 1 ended in a verdict"));
ok("panel: fineprint ethic", html.includes("Published because they are the only reason to trust a verdict"));
ok("panel: rows in order", (()=>{ const i=["settled undisputed","settled by vote","closed without a decision","expired unanswered","live now","dispute rounds failed","GNOT burned here"].map(k=>html.indexOf(k)); return i.every((x,j)=>x>=0 && (j===0||x>i[j-1])); })());
ok("panel: no banned words", !/backing|redeem\b|profit|APR|market cap|TVL/i.test(html));

// live skeleton
CFG.mode='live';
const htmlL = courtRecordPanel("orem", {claims:33});
ok("live: last-20 scope label", htmlL.includes("of the last 20 claims"));
ok("live: skeleton ellipses", htmlL.includes("…"));
const htmlL2 = courtRecordPanel("orem", {claims:11});
ok("live small court: of this court's 11", htmlL2.includes("of this court's 11 claims"));
CFG.mode='demo';

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
