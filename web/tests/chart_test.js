// Chart harness v2: slices the LIVE functions from web/index.html (the old
// copy had drifted). Pins: the real-record branch (step-after geometry, seam,
// knee, freeze, snap, labels), the parser/merge, and the two fallbacks
// byte-compatible with the pre-series build.
const _log=console.log; let BAD=false;
console.log=(...a)=>{ if(/BROKEN|\(BAD\)|NaN!|missing-note|unexpected:|no-ref|no-band|FAIL:/.test(a.join(" "))) BAD=true; _log(...a); };
process.on('exit',()=>{ _log(BAD?"FAILURES":"ALL PASS"); process.exitCode=BAD?1:0; });

const fs=require('fs');
const src=fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(f,t){const a=src.indexOf(f);if(a<0)throw new Error("missing "+f);const b=src.indexOf(t,a);if(b<0)throw new Error("missing "+t);return src.slice(a,b);}
global.document={addEventListener:()=>{},getElementById:()=>null};
global.CFG={mode:'demo'};
let LIVE=false; global.isLive=()=>LIVE;

let code='var NOW=4800000, WEEK=120960, BLOCK_SECS=5;\n';
code+=slice('function esc(','\n');
code+=slice('function fmtN(','function ugnot(');
code+='const sideName=v=>v===0?"YES":"NO";\n';
code+=slice('function pctYes(','\n');
code+=slice('function fnv1a(','function ratios(');
code+=slice('function ratios(','function demoSeries(');
// Round 28 split the literal: DEMO_CHAIN (generated) + DEMO_OVERLAY
// (hand-written: desc, nested folders, relations, voteEndsAt), joined by
// mergeDemo. Build the merged object the way the page does.
code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED').replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED').replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
code+=slice('function demoSeries(','async function fetchStakeSeries(');
code+=slice('function signalChart(','function chartChips(');
let code2='';
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++;console.log("FAIL:",n);} else console.log("ok:",n); };
const claims=DEMO.claims;
const serOf=k=>mergeStakeSeries(parseStakeSeries(claims[k].seriesH),parseStakeSeries(claims[k].seriesD),NOW);

// P1-P3: parser hygiene
ok("P1 rows parse", parseStakeSeries("hourly,720,6667,0;10:5:2,12:6:2").rows.length===2);
ok("P1 header fields", (()=>{const p=parseStakeSeries("daily,17280,278,1;");return p.grain==="daily"&&p.width===17280&&p.nowE===278&&p.more===true&&p.rows.length===0;})());
ok("P3 junk rejected", [null,undefined,"",";","x,720,1,0;","hourly,720,1,0;1:2","hourly,720,1,0;1:2:x","hourly,720,1,2;","deadbeef"].every(v=>parseStakeSeries(v)===null));
ok("P3 unsorted input sorted", (()=>{const p=parseStakeSeries("hourly,720,9,0;5:1:1,3:2:2");return p.rows[0][0]===3;})());
ok("P3 zero-total row keeps share null", (()=>{const m=mergeStakeSeries(parseStakeSeries("hourly,720,9,0;3:5:5,5:0:0"),null,NOW);return m.pts[1][1]===null;})());
ok("merge clamps future epochs to now", (()=>{const m=mergeStakeSeries(parseStakeSeries("hourly,720,999999,0;999999:1:1"),null,NOW);return m.pts[0][0]===NOW;})());
ok("merge: daily below hourly only", (()=>{const m=serOf("orem/1");
  const hs=6510*720; const dailyPart=m.pts.filter(p=>p[0]<hs);
  return dailyPart.length===6 && m.pts.length===6+8;})());

// P4: step geometry — no interpolation commands, path not polyline
LIVE=false;
const h1=signalChart("orem",1,claims["orem/1"],null,serOf("orem/1"));
ok("P4 real branch draws a path", h1.includes('<path class="ln"') && !h1.includes('<polyline class="ln"'));
const dAttr=(h1.match(/<path class="ln" d="([^"]+)"/)||[])[1]||"";
ok("P4 step-after only (M/H/V, no L/C in the line)", /^M [\d. -]+(?: H [\d.]+(?: V [\d.]+)?)*$/.test(dAttr));
ok("P4 area closes to the axis", h1.includes('<path class="ar"') && / Z"><\/path>/.test(h1));

// P5: seam and knee
ok("P5 orem/1 seam, linear (no knee)", h1.includes('class="seam"'));
const hl=signalChart("ledger",1,claims["ledger/1"],null,serOf("ledger/1"));
ok("P5 ledger/1 knee engages at Xs=217.3", hl.includes('x1="217.3"'));
const h2=signalChart("orem",2,claims["orem/2"],null,serOf("orem/2"));
ok("P5 orem/2 no seam (all within the week)", !h2.includes('class="seam"'));

// P6: freeze — flat to the end, endS frozen
ok("P6 frozen endS", h2.includes(">frozen<"));
ok("P6 records-begin event", h1.includes("records begin"));

// P7: fallbacks byte-compatible
const noSer=signalChart("orem",7,claims["orem/7"],null,null);
ok("P7 demo fallback keeps the synthesized note",
   /illustrative|drawn here, not read from the chain/.test(noSer)
   && /chain (records|keeps) only those three numbers/.test(noSer));
ok("P7 demo fallback still a polyline", noSer.includes('<polyline class="ln"'));
LIVE=true;
const lh=signalChart("orem",2,claims["orem/2"],5000000,null);
ok("P7 live fallback: ref+band, no line", lh.includes('class="ref"') && lh.includes('class="band"') && !lh.includes('class="ln"'));
const lhReal=signalChart("orem",2,claims["orem/2"],4800000,serOf("orem/2"));
// THE SOURCE NOTE IS A DISCLOSURE, NOT A LEGEND. On a live claim it described
// the sampling interval — trivia under a chart whose axis already says what it
// plots. In demo mode it is the sentence that stops a reader taking sample data
// for a court's record, so that is the one that stays.
ok("P7 live real: no source note under a real chart", !lhReal.includes("srcnote"));
ok("P7 demo real: still says it is a sample", (()=>{ LIVE=false;
  const dr=signalChart("orem",2,claims["orem/2"],4800000,serOf("orem/2"));
  LIVE=true; return dr.includes("srcnote") && dr.includes("sample data"); })());
LIVE=false;

// P8: every DEMO series is self-consistent
for(const k of Object.keys(claims)){
  const d=claims[k];
  if(!d.seriesH && !d.seriesD) continue;
  const m=serOf(k);
  ok("P8 "+k+" parses", !!m);
  const last=m.pts[m.pts.length-1];
  ok("P8 "+k+" last=pools", last[2]===d.yesStake && last[3]===d.noStake);
  if(d.phase!=="open" && d.settleAt) ok("P8 "+k+" pre-freeze", last[0]<=d.settleAt-51840);
}

/* P8b: THE AXIS STRIP AGREES WITH THE PLOT. The domain runs to the furthest
   event — a settle deadline, a reopen close, a vote close — but the right-hand
   label was hardcoded to `now`, so on any claim with something scheduled ahead
   of it the axis end read as today while the last marker on the plot was days
   later. The reader who caught it was comparing the strip to the ladder: chart
   ends the 15th, vote closes the 25th.
   Asked of the RIGHT label against the FURTHEST event, not against a fixed
   string, so it holds for a claim with nothing scheduled too. */
{
  const zoneOf = h => (h.match(/<text class="zone"[^>]*>([^<]*)<\/text>/g)||[])
    .map(t=>t.replace(/<[^>]*>/g,""));
  // orem/3 is disputed: a vote close sits days past now.
  const disp = signalChart("orem",3,claims["orem/3"],NOW,null);
  const zd = zoneOf(disp);
  ok("P8b the axis end is not labelled now when the plot runs past now",
     zd.length===2 && zd[1]!=="now" && /^in ≈/.test(zd[1]));
  // orem/4 is settled: nothing is scheduled, so the edge IS now and still says so.
  const done = zoneOf(signalChart("orem",4,claims["orem/4"],NOW,null));
  ok("P8b ...and still says now when nothing is scheduled ahead",
     done.length===2 && done[1]==="now");
  // The distance named is the distance to the LAST marker, within rounding.
  const d3 = claims["orem/3"];
  const far = Math.max(NOW, d3.settleAt||0, d3.escrowUntil||0, d3.voteEndsAt||0);
  const want = Math.round(Math.abs(far-NOW)*5/86400*10)/10;
  ok("P8b the distance is the distance to that last marker",
     zd[1] === "in ≈"+want+"d");
  // A dated chart names the edge's date, not today's.
  const ans = zoneOf(signalChart("orem",2,claims["orem/2"],NOW,serOf("orem/2")));
  ok("P8b a dated strip stamps the edge, not now",
     / · in ≈/.test(ans[1]) && !/ · now$/.test(ans[1]));
}

// P9: labels + §7.4
ok("P9 demo real srcnote", h1.includes("a sample series in the chain's real form"));
// NO FIGCAPTION. It named the axis, then the three series, then printed the
// three ratios again — over a labelled chart, above a bar that states the same
// split. The aria-label still carries every number it did, so the check moves
// to the description a screen reader actually gets.
ok("P9 no caption row over the chart", !h1.includes("<figcaption"));
ok("P9 the ratios survive where they are read aloud",
   /aria-label="[^"]*lifetime/.test(h1) && /aria-label="[^"]*now /.test(h1));
ok("P9 aria recorded history", h1.includes("recorded history"));
ok("P9 §7.4 sweep", ![h1,h2,hl,noSer,lhReal].some(x=>/backing|redeem|APR|profit|return on|price rises/i.test(x)));

// P10: terminal snap only when live pools differ from the last point
const snapClaim={...claims["orem/1"], yesStake:60_000_000}; // inst=83.3 vs last 77.4
const hS=signalChart("orem",1,snapClaim,null,serOf("orem/1"));
const dS=(hS.match(/<path class="ln" d="([^"]+)"/)||[])[1]||"";
ok("P10 snap riser present", / V [\d.]+$/.test(dS));
ok("P10 no snap when equal", !/ V [\d.]+$/.test(dAttr.slice(dAttr.lastIndexOf("H"))));

// legacy diagnostics kept (fallback shapes)
const lh3=signalChart("orem",1,claims["orem/1"],null,null);
console.log("demo no-series:", lh3.includes("synthesized shape")?"note-ok":"missing-note", lh3.includes("NaN")?"NaN!":"clean");

// the clock: dates decide, heights are reference (owner ruling)
code2 = slice('function parseTimeline(','function resolutionLadder(');
eval(code2);
ok("timeline parses the realm grammar", (()=>{const t=parseTimeline("opened:1787000000:4600000;now:1787054400:4800000");
  return t && t.opened.t===1787000000 && t.opened.h===4600000;})());
ok("timeline rejects junk / demands now", parseTimeline("garbage")===null && parseTimeline("opened:1:2")===null);
ok("dates render UTC, spelled out", stampDate(1787054400,true)==="18 Aug 2026, 12:00 UTC" && stampDate(1787054400,false)==="18 Aug 2026");
ok("relative words both directions", sinceWords(1787054400,1787054400-86400)==="1 day ago" && sinceWords(1787054400,1787054400+432000)==="in 5 days");
ok("every demo claim with a timeline parses", Object.entries(DEMO.claims).filter(([,d])=>d.timeline).every(([k,d])=>{
  const t=parseTimeline(d.timeline); return t && t.now && t.opened && t.opened.t>0;}));
ok("no claim is stamped in the future", Object.values(DEMO.claims).filter(d=>d.timeline).every(d=>{
  const t=parseTimeline(d.timeline); return t.opened.t<=t.now.t && (!t.answered||t.answered.t<=t.now.t) && (!t.verdict||t.verdict.t<=t.now.t);}));
console.log(fail? fail+" FAILURES":"ok all "+"chart pins");
