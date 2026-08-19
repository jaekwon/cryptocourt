// P6 harness: the seeded-chain banner. Keyed on Fabricated (survives sealing),
// cached per RPC, silent in demo mode, silent on a realm without the accessor.
const fs = require('fs');
const SRC = require('path').join(__dirname,'..','index.html');
const src = fs.readFileSync(SRC, 'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
let EL = {hidden:true, innerHTML:""};
global.document = { getElementById: id => id==="tcbanner"? EL : null, addEventListener: ()=>{} };
global.CFG = { mode:"live", rpc:"http://127.0.0.1:26706" };
global.isLive = ()=> CFG.mode==='live';
let ANSWERS = {}, CALLS = [];
global.qeval = async expr => {
  CALLS.push(expr);
  const k = expr.replace(/\(.*/,"");
  if(!(k in ANSWERS)) throw new Error("unknown function "+expr);
  return ANSWERS[k];
};
let code = '';
code += slice('function fmtN(', 'function ugnot(');
code += slice('function parseTyped(', 'const gstr').replace(/const one =/,'var one =').replace(/const tup =/,'var tup =');
code += slice('let TCFAB = null', '/* WHERE AN EMBED');
code += slice('async function paintTestClockBanner(', 'async function render()');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };
// The cache is per-RPC and lives in the eval scope, so the honest way to get a
// cold read is a fresh endpoint — the same thing that happens when a user
// repoints the overlay at another node.
let PORT = 27000;
const reset = ()=>{ CFG.rpc = "http://127.0.0.1:"+(PORT++); EL={hidden:true,innerHTML:""}; CALLS=[]; };

(async ()=>{
  // sealed seeded chain — the case that regressed
  reset();
  ANSWERS = {"TestClockFabricated":"(true bool)", "TestClockActive":"(false bool)",
             "TestClockPeakSkew":"(7257601 int64)", "TestHeightPeakSkew":"(0 int64)"};
  await paintTestClockBanner();
  ok("sealed chain shows the banner", EL.hidden===false);
  ok("says fabricated", /fabricated/i.test(EL.innerHTML));
  ok("says sealed, not still-open", /sealed/i.test(EL.innerHTML) && !/can move again/.test(EL.innerHTML));
  ok("converts skew to days (84)", /84 days/.test(EL.innerHTML));
  // The overlay used to assert "Heights ... are real" too. The override moves
  // height, so that clause went the way of the realm banner's.
  ok("no longer claims heights are real", /Balances and stakes are real/.test(EL.innerHTML)
     && !/Heights, balances/.test(EL.innerHTML));

  // armed chain — still drivable
  reset();
  ANSWERS = {"TestClockFabricated":"(true bool)", "TestClockActive":"(true bool)",
             "TestClockPeakSkew":"(3600 int64)", "TestHeightPeakSkew":"(0 int64)"};
  await paintTestClockBanner();
  ok("armed chain says it can still move", /can move again/.test(EL.innerHTML));
  // 3600s rounds to 0 days and no blocks moved, so the banner names NEITHER
  // rather than claiming "0 days" — which reads as "nothing was moved".
  ok("a sub-day, no-block chain claims no movement", !/moved forward/.test(EL.innerHTML));

  // the override moves HEIGHT too, and a chain advanced only in height used to
  // read "moved forward 0 days"
  reset();
  ANSWERS = {"TestClockFabricated":"(true bool)", "TestClockActive":"(false bool)",
             "TestClockPeakSkew":"(0 int64)", "TestHeightPeakSkew":"(120960 int64)"};
  await paintTestClockBanner();
  ok("height-only chain names the blocks", /120,960 blocks/.test(EL.innerHTML));
  ok("height-only chain does not claim 0 days", !/0 days/.test(EL.innerHTML));

  reset();
  ANSWERS = {"TestClockFabricated":"(true bool)", "TestClockActive":"(false bool)",
             "TestClockPeakSkew":"(7257601 int64)", "TestHeightPeakSkew":"(19500 int64)"};
  await paintTestClockBanner();
  ok("both halves named together", /84 days and 19,500 blocks/.test(EL.innerHTML));

  // an older realm has no height read at all: absent must not become zero
  reset();
  ANSWERS = {"TestClockFabricated":"(true bool)", "TestClockActive":"(false bool)",
             "TestClockPeakSkew":"(7257601 int64)"};
  await paintTestClockBanner();
  ok("a realm without the height read still banners", EL.hidden===false);
  ok("and names only the days", /84 days/.test(EL.innerHTML) && !/blocks/.test(EL.innerHTML));

  // ordinary chain — never armed
  reset();
  ANSWERS = {"TestClockFabricated":"(false bool)", "TestClockActive":"(false bool)",
             "TestClockPeakSkew":"(0 int64)"};
  await paintTestClockBanner();
  ok("ordinary chain shows nothing", EL.hidden===true && EL.innerHTML==="");
  ok("ordinary chain costs ONE query", CALLS.length===1);

  // realm without the accessor (older deploy) — silence, not an error banner
  reset();
  ANSWERS = {};
  await paintTestClockBanner();
  ok("realm without the entrypoint stays silent", EL.hidden===true);

  // demo mode never asks the chain anything
  reset(); CFG.mode="demo";
  ANSWERS = {"TestClockFabricated":"(true bool)"};
  await paintTestClockBanner();
  ok("demo mode shows nothing", EL.hidden===true);
  ok("demo mode makes no query", CALLS.length===0);
  CFG.mode="live";

  // cached per endpoint: one query per node, not one per page
  reset();
  ANSWERS = {"TestClockFabricated":"(true bool)", "TestClockActive":"(false bool)",
             "TestClockPeakSkew":"(7257601 int64)"};
  await paintTestClockBanner();
  const first = CALLS.length;
  await paintTestClockBanner();
  await paintTestClockBanner();
  ok("cached across renders", CALLS.length===first);
  CFG.rpc = "http://127.0.0.1:"+(PORT++);
  await paintTestClockBanner();
  ok("re-queries when the endpoint changes", CALLS.length>first);

  // --- the cache must not hand out a placeholder while it is still reading ---
  // render() calls paintTestClockBanner() WITHOUT awaiting it and then runs the
  // route, so an embed's sourceNote() lands inside the banner's in-flight read.
  // The cache used to publish its key and a null value first, so the second
  // caller got null — "no test clock" — and an embed on a seeded chain showed no
  // disclosure at all while the clip a second later showed it correctly. Only a
  // real chain surfaced it; demo mode returns before touching this.
  reset();
  ANSWERS = {"TestClockFabricated":"(true bool)", "TestClockActive":"(false bool)",
             "TestClockPeakSkew":"(7257601 int64)", "TestHeightPeakSkew":"(0 int64)"};
  let SLOW = 0;
  const realQ = global.qeval;
  global.qeval = async expr => { SLOW++; await new Promise(r=>setTimeout(r,15)); return realQ(expr); };
  const [a, b2] = await Promise.all([testClockState(), testClockState()]);
  global.qeval = realQ;
  ok("a concurrent reader does not get a null placeholder", b2 !== null,
     "second caller saw " + JSON.stringify(b2));
  ok("both concurrent readers get the same object", a === b2);
  ok("and the chain is read once, not twice", SLOW <= 4, "reads=" + SLOW);
  // Same question after it has resolved: still cached, still no re-read.
  const before = SLOW;
  ok("a later reader is served from cache", (await testClockState()) === a && SLOW === before);

  // structure + copy contract
  ok("banner lives outside #main", src.includes('<div id="tcbanner" role="status" hidden></div>'));
  ok("render() paints it every route", /async function render\(\)\{\s*\n\s*const seq = \+\+renderSeq;\s*\n\s*paintTestClockBanner\(\);/.test(src));
  ok("asks Fabricated, not Active, for the decision", src.includes('await one("TestClockFabricated()")'));
  ok("§7.4 clean", !/\bmoney\b|backing|redeem\b|profit|APR/i.test(slice('let TCFAB = null','async function render()')));
  ok("style token exists", src.includes(".tcbar{"));

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
