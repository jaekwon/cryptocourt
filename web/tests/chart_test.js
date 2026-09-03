// Chart harness v2: slices the LIVE functions from web/index.html (the old
// copy had drifted). Pins: the real-record branch (step-after geometry, seam,
// knee, freeze, snap, labels), the parser/merge, and the two fallbacks
// byte-compatible with the pre-series build.
const _log=console.log; let BAD=false, DONE=false;
console.log=(...a)=>{ if(/BROKEN|\(BAD\)|NaN!|missing-note|unexpected:|no-ref|no-band|FAIL:/.test(a.join(" "))) BAD=true; _log(...a); };
/* A CRASH IS NOT A PASS. The exit hook printed ALL PASS from `BAD` alone, and
   `BAD` only ever sees assertions that RAN — so a throw partway down the file
   ended the run, skipped every check after it, and reported green, with the
   stack trace scrolling past underneath. It did exactly that: a missing
   stampDate in the slice killed the last block and the harness said ALL PASS.
   DONE is set on the last line; anything that stops the file before then is a
   failure whether or not an assertion noticed. */
process.on('uncaughtException', e=>{ BAD=true; _log("FAIL: uncaught —", (e&&e.stack)||e); });
process.on('exit',()=>{ if(!DONE) BAD=true;
  _log(BAD?"FAILURES":"ALL PASS"); process.exitCode=BAD?1:0;
  if(!DONE) _log("(the harness did not reach its end)"); });

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
code += slice('const SETTLE_DELAY', '\n').replace('const ','var ') + '\n';   // sliced, never retyped: a fourth copy of the number is the bug
code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED').replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED').replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
code+=slice('function demoSeries(','async function fetchStakeSeries(');
code+=slice('function chartHoverAt(','document.addEventListener("mousemove"');
code+=slice('function parseTimeline(','function resolutionLadder(');  // + MON, stampDate, sinceWords
code+=slice('function resolutionLadder(','function resolutionSection(');
code+=slice('function signalChart(','function chartChips(');
// chartChips too: the chip row is where the coin's mark meets a container that
// styles spans, and both faults below were invisible until they were rendered.
code+=slice('function chartChips(','\n/* DOES THE TICKET HOLD');
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
  if(d.phase!=="open" && d.settleAt) ok("P8 "+k+" pre-freeze", last[0]<=d.settleAt-SETTLE_DELAY);
}

/* P8a: DATES COME FROM THE CHAIN'S ANCHORS, NOT FROM A NOMINAL BLOCK RATE.
   heightDater took tl.now alone and walked backwards at BLOCK_SECS, which is
   right only on a chain that never paused, restarted, or had its clock moved.
   Nothing caught it because every fixture in this repo was BUILT on that
   assumption — share_test's says so in as many words ("every t/h pair here sits
   on the same 5s-per-block line through now"). So this fixture deliberately
   does not: it is a chain that produced blocks far slower than nominal early on
   and at the nominal rate lately, which is what a seeded or restarted chain
   looks like, and is the shape that put the ladder's answer five years from the
   chart's. */
{
  const HOUR=3600, DAY=86400;
  // opened: 4,000,000 blocks before now but 1800 days ago — ~39s a block, not 5.
  const TL={ opened:{t:1600000000, h:1000},
             answered:{t:1600000000+1500*DAY, h:3000},
             now:{t:1600000000+1800*DAY, h:5000} };
  const zdt=heightDater(TL);
  ok("P8a exact at every anchor the chain published",
     zdt(TL.opened.h)===TL.opened.t && zdt(TL.answered.h)===TL.answered.t && zdt(TL.now.h)===TL.now.t);
  // Halfway between two anchors in HEIGHT is halfway between them in TIME.
  const midH=(TL.opened.h+TL.answered.h)/2, midT=(TL.opened.t+TL.answered.t)/2;
  ok("P8a interpolates between them", Math.abs(zdt(midH)-midT) < 1);
  // The flat-rate version would put opened 4,000 blocks × 5s = 5.8 hours before
  // now. The chain says 1,800 days. That gap IS the bug.
  const flat = TL.now.t + (TL.opened.h-TL.now.h)*5;
  ok("P8a and does not walk back at the nominal interval",
     Math.abs(zdt(TL.opened.h)-flat) > 1000*DAY);
  // Before the first anchor it continues on the first segment's own rate —
  // that is still history.
  const r0=(TL.answered.t-TL.opened.t)/(TL.answered.h-TL.opened.h);
  ok("P8a extrapolates backwards on the nearest segment's rate",
     Math.abs(zdt(TL.opened.h-100) - (TL.opened.t-100*r0)) < 1);
  /* AHEAD OF NOW IT USES THE NOMINAL CADENCE, and that asymmetry is the fix. An
     observed rate says what the chain DID; it does not predict. This chain
     averaged ~39s a block, so carrying that forward turned a deadline a few
     thousand blocks out into years — "25 Mar 2032 · in ≈1927.2d" over a vote
     that closes in five days. The ladder projects the future at BLOCK_SECS, so
     the chart must too or the two contradict each other on the same screen. */
  const ahead = 86400/5;      // one nominal day of blocks past now
  ok("P8a projects forward at the nominal interval, not at the past's rate",
     zdt(TL.now.h+ahead) === TL.now.t + ahead*5);
  const pastRate=(TL.now.t-TL.answered.t)/(TL.now.h-TL.answered.h);
  ok("P8a ...which the observed rate would have called years",
     Math.abs(zdt(TL.now.h+ahead) - (TL.now.t+ahead*pastRate)) > 300*DAY);
  // settle and reopen are deadlines the realm computed FORWARD. Anchoring on one
  // would feed a projection back in as evidence, so a wild value must not move
  // any date that came from a block the chain actually reached.
  const withSettle=heightDater(Object.assign({}, TL, {settle:{t:1, h:4000}, reopen:{t:2, h:4500}}));
  ok("P8a a projected deadline is not an anchor",
     withSettle(TL.answered.h)===TL.answered.t && withSettle(midH)===zdt(midH));
  // One anchor is all a pre-timeline realm gives: fall back, do not crash.
  const lone=heightDater({now:{t:1000, h:50}});
  ok("P8a one anchor still dates, at the nominal interval", lone(40)===1000-50);
  ok("P8a no anchors at all, no dater", heightDater(null)===null && heightDater({})===null);
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
  // The strip is HTML under the plot now, not text inside it — placing its two
  // ends absolutely only held while they were short, and the mobile font sizes
  // are not short. Same two readings, read from where they live.
  const zoneOf = h => (h.match(/<div class="chartzone">([\s\S]*?)<\/div>/)||["",""])[1]
    .split(/<\/?span>/).map(t=>t.trim()).filter(Boolean);
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

/* P8c: THE MARKER SITS WHERE THE CHAIN SAYS, NOT WHERE THE PAGE DERIVED. The
   answered height was always settleAt−SETTLE_DELAY — the window counted back
   in blocks — while the ladder next to it uses the realm's own answered stamp.
   On a chain where those disagree the same event is on one page twice, at two
   moments; the reader saw an "answered yes" marker near the left edge of a
   window that began long after the ladder said the answer was posted. */
{
  const DAY=86400;
  const TL={ opened:{t:1600000000, h:1000},
             answered:{t:1600000000+1500*DAY, h:3000},
             now:{t:1600000000+1800*DAY, h:5000} };
  // The chain answered at 3,000 — 300 days back on its own clock. settleAt−SETTLE_DELAY
  // lands at 4,990, ten blocks before now: the same event, a year apart.
  const c={title:"T", yesStake:10, noStake:3, statusText:"answered", phase:"answered",
           answer:0, settleAt:5000+SETTLE_DELAY-10, yesConv:10, noConv:3};
  const SER={pts:[[4900,60],[4950,62]], firstH:4900};
  const zone = h => (h.match(/<div class="chartzone">([\s\S]*?)<\/div>/)||["",""])[1]
    .split(/<\/?span>/).map(t=>t.trim()).filter(Boolean);
  LIVE=true;
  const withTl = zone(signalChart("orem",9,c,5000,SER,TL));
  const noTl   = zone(signalChart("orem",9,c,5000,SER,null));
  LIVE=false;
  // x0 = min(firstH, ansH). With the chain's answer height that is 3,000, so
  // the window opens on the answer and the strip says how long ago the CHAIN
  // says that was — not 100 blocks × 5s.
  ok("P8c the window opens on the chain's own answer height, dated by the chain",
     /≈300d ago/.test(withTl[0]), withTl[0]);
  ok("P8c ...which the nominal interval would have called under a day",
     !/≈0(\.\d)?d ago/.test(withTl[0]), withTl[0]);
  // No timeline: no dater, so heights — and the derived answer height, which is
  // all a realm too old to publish a timeline can offer.
  ok("P8c without a timeline it still draws, on the derived height",
     /^block /.test(noTl[0]), noTl[0]);
}

/* P8d: THE TWO SURFACES NAME THE SAME DAY. The chart's axis strip and the
   ladder under it describe the same claim, and three separate bugs in a row
   were the same shape — one of them dated an event and the other dated it
   differently, on the same screen, and every check passed because each was only
   ever asked about itself.
   So: render both from one claim and one timeline, on a chain whose observed
   cadence is nothing like the nominal one, and compare the DAYS they print. */
{
  const DAY=86400;
  // a chain that stalled: 1800 days of wall clock across 4000 blocks
  const TL={ opened:{t:1600000000, h:1000},
             answered:{t:1600000000+1500*DAY, h:3000},
             now:{t:1600000000+1800*DAY, h:5000} };
  const NOWH=5000;
  const c={title:"T", yesStake:10, noStake:3, statusText:"disputed", phase:"disputed",
           answer:0, round:1, voteEndsAt:NOWH+86400/5*5,   // five nominal days out
           yesConv:10, noConv:3};
  LIVE=true;
  const chart = signalChart("orem",9,c,NOWH,{pts:[[4900,60],[4950,62]], firstH:4900},TL);
  LIVE=false;
  const zones = (chart.match(/<div class="chartzone">([\s\S]*?)<\/div>/)||["",""])[1]
    .split(/<\/?span>/).map(t=>t.trim()).filter(Boolean);
  const ladder = resolutionLadder(c, NOWH, TL, false, false);
  // The furthest thing on the plot is the vote close, and the ladder has a row
  // for it. Both spell a date; they must spell the same one.
  const dayOf = str => (str.match(/\d{1,2} [A-Z][a-z]{2} \d{4}/)||[])[0];
  const chartEnd = dayOf(zones[1]);
  const ladderVote = dayOf((ladder.match(/vote closes[\s\S]{0,220}?<\/div>/)||[""])[0]
                     + (ladder.split("vote closes")[1]||"").slice(0,200));
  ok("P8d the chart's right edge and the ladder's vote row agree",
     !!chartEnd && chartEnd===ladderVote, `chart=${chartEnd} ladder=${ladderVote}`);
  // And it is five days out, not five days scaled by a stalled chain's history.
  ok("P8d ...and it is the five days the vote actually has",
     /in ≈5(\.\d)?d/.test(zones[1]), zones[1]);
}

/* P8e: THE HOVER READOUT. It replaced a ladder of five fixed dates under the
   plot with the date of the point actually under the pointer, so the points and
   their times ride on the svg — and they must be the SAME times the axis strip
   and the ladder use, which is the invariant this chart keeps breaking. */
{
  const DAY=86400;
  const TL={ opened:{t:1600000000, h:1000},
             answered:{t:1600000000+1500*DAY, h:3000},
             now:{t:1600000000+1800*DAY, h:5000} };
  const SER={pts:[[4900,60],[4950,62],[4990,64]], firstH:4900};
  LIVE=true;
  const h=signalChart("orem",9,{title:"T",yesStake:10,noStake:3,statusText:"answered",
                                phase:"answered",answer:0,settleAt:5000+SETTLE_DELAY},5000,SER,TL);
  const bare=signalChart("orem",9,{title:"T",yesStake:10,noStake:3,statusText:"open",
                                   phase:"open"},5000,null,TL);
  LIVE=false;
  const pts=(h.match(/data-hov="([^"]*)"/)||[])[1];
  ok("P8e every drawn point is hoverable", !!pts && pts.split(";").length===SER.pts.length);
  ok("P8e ...and the layer is there to read them out", h.includes('class="xh"'));
  // The times on the points are the dater's, not a second opinion.
  const zdt=heightDater(TL);
  const last=pts.split(";").pop().split(",");
  ok("P8e a point's time is the one the axis would give it",
     +last[2] === Math.round(zdt(SER.pts[SER.pts.length-1][0])));
  ok("P8e ...and its share is the share that was plotted",
     +last[3] === SER.pts[SER.pts.length-1][1]);
  /* A CHART WITH NO SERIES STILL HAS MARKERS. An open claim on a live court
     draws opened and now and nothing between them; before, that chart had no
     hover layer at all, so the two things on it answered nothing. It carries a
     layer with an empty point list and a populated event list. */
  ok("P8e a chart with no series still offers its markers",
     /data-hov=""/.test(bare) && /data-hovev="[^"]+"/.test(bare) && bare.includes('class="xh"'));

  // chartHoverAt: nearest by x, events first, and nothing at all past both.
  const fake = (pts, evs) => ({ getAttribute:k=> k==="data-hov"? pts
                                : k==="data-hovev"? (evs||"") : "1",
                                getBoundingClientRect:()=>({left:0, width:640}) });
  const svg = fake("100,50,111,60;200,40,222,62");
  ok("P8e picks the point nearest the pointer",
     chartHoverAt(svg, 110).t===111 && chartHoverAt(svg, 190).t===222);
  ok("P8e and reads out nothing beyond the series",
     chartHoverAt(svg, 400)===null && chartHoverAt(svg, 0)===null);
  ok("P8e no points and no events, no reading",
     chartHoverAt(fake("",""), 10)===null);
  // A MARKER ANSWERS WHERE IT IS, and wins over the line when you are on it —
  // "settle deadline" and "now" are the two marks a reader points AT, and they
  // used to give a native tooltip while the line beside them gave a date.
  const withEv = fake("100,50,111,60;200,40,222,62", "300,777,settle deadline;480,888,now");
  ok("P8e a marker names itself and its date",
     chartHoverAt(withEv, 300).label==="settle deadline"
     && chartHoverAt(withEv, 300).t===777
     && chartHoverAt(withEv, 480).label==="now");
  ok("P8e ...on the axis, not on the line", chartHoverAt(withEv, 480).y===124);
  ok("P8e a point still wins where the line is and no marker is near",
     chartHoverAt(withEv, 200).share===62);
  ok("P8e ...and the marker wins when the pointer is on it",
     chartHoverAt(fake("300,50,111,60", "300,777,settle deadline"), 300).label==="settle deadline");
  ok("P8e still nothing in the empty stretches",
     chartHoverAt(withEv, 620)===null);
}

/* P8f: THE PLOT STAYS INSIDE ITS OWN BOX AT EVERY FONT SIZE. The stylesheet
   scales chart text to 20 units in a 640-unit viewBox on a narrow screen — the
   right call for legibility, and never measured: at that size the two ends of
   the axis strip ran through each other, event labels reached 688 in a 640-wide
   box, and the top tick's cap height went above the top edge. All of it stayed
   on screen only because an svg does not clip by default, which is luck, not
   layout. web/tests/browser measures the rendered boxes; these pin the emitter
   decisions those measurements forced. */
{
  const DAY=86400;
  const TL={ opened:{t:1600000000,h:1000}, answered:{t:1600000000+1500*DAY,h:3000},
             now:{t:1600000000+1800*DAY,h:5000} };
  const c={title:"T",yesStake:10,noStake:3,statusText:"answered",phase:"answered",
           answer:0,settleAt:5000+SETTLE_DELAY};
  LIVE=true;
  const h=signalChart("orem",9,c,5000,{pts:[[4900,60],[4990,64]],firstH:4900},TL);
  LIVE=false;
  ok("P8f the axis strip is html, so its ends cannot be placed on each other",
     h.includes('<div class="chartzone">') && !/text class="zone"/.test(h));
  // Right-anchored at 638: the gutter holds a reading at any size.
  ok("P8f the scale is anchored to the inside edge, not started at 610",
     !/class="tickL[^"]*" x="61[02]"/.test(h)
     && (h.match(/<text class="tickL[^"]*" x="638" y="\d+" text-anchor="end">/g)||[]).length===3);
  ok("P8f ...and so is the end readout, which used to start at 612",
     !/class="end[LS]" x="612"/.test(h)
     && /<text class="endL" x="638" text-anchor="end"/.test(h));
  // An event label near the right grows leftwards instead of off the edge. The
  // estimate is taken at the LARGEST font the stylesheet applies, so the flip is
  // decided for the worst case rather than the emitter's imagined one.
  const labels=[...h.matchAll(/<text class="evtL[^"]*" x="([\d.]+)"( text-anchor="end")? y=/g)]
    .map(m=>({x:+m[1], end:!!m[2]}));
  ok("P8f every event label is inside the plot at the mobile size",
     labels.length>0 && labels.every(l=>l.end? l.x<=606 : l.x+2*12*20<=700));
  ok("P8f ...and at least one of them had to be flipped to stay there",
     labels.some(l=>l.end));
  // The top tick's baseline has a floor for the same reason.
  const top=(h.match(/<text class="tickL[^"]*" x="638" y="(\d+)"/)||[])[1];
  ok("P8f the top tick sits low enough for a 20-unit cap height", +top>=19);
  // A tick behind the readout is marked, not dropped — the breakpoint that hides
  // the readout is the one that brings the tick back.
  /* A tick behind the readout is MARKED, not omitted — asked of the emitter and
     the stylesheet together, because the pair is the whole mechanism: whether a
     given claim happens to cover a tick depends on where its share lands, and
     what must hold is that a covered one can come back. */
  ok("P8f a covered tick is marked rather than omitted",
     /class="tickL\$\{covered\?" covered":""\}"/.test(src)
     && src.includes(".bigchart .tickL.covered{display:none}")
     && /max-width:820px\)\{[\s\S]*?\.bigchart \.tickL\.covered\{display:inline\}/.test(src));
  // and the case itself renders: a claim whose end share sits on the top tick
  const near=signalChart("orem",9,{title:"T",yesStake:99,noStake:1,statusText:"answered",
                                   phase:"answered",answer:0,settleAt:5000+SETTLE_DELAY},5000,null,TL);
  ok("P8f ...and a claim that covers one actually marks it",
     /class="tickL covered"/.test(near));
}

/* P8g: LABELS ARE HALOED, because the chart draws lines through the space it
   writes in. The lifetime reference spans the full width at whatever height
   that ratio lands on — on a claim near 93% it went through the middle of
   "records begin" — the now rule is full height by design and crossed "settle
   deadline", and gridlines cross the ticks. Packing labels away from every line
   has no solution on a 640x150 plot; a stroke the colour of the ground, painted
   under the glyph, costs no layout at all.
   Verified computed in a browser besides: every text class reports paintOrder
   stroke with a 3px stroke, and .xht reports none. */
{
  ok("P8g every chart label is stroked under its glyphs",
     /\.bigchart text\{paint-order:stroke fill; stroke:var\(--paper\); stroke-width:3px;/.test(src));
  ok("P8g ...and the hover pill is exempt, being reversed out of its own plate",
     src.includes(".bigchart .xht{stroke:none}"));
}

/* P8h: THE CHART'S MARKERS AND THE LADDER'S ROWS ARE THE SAME EVENTS. P8d
   compared the axis strip to the ladder; the markers were never compared to
   anything, and hovering them turned up two disagreements at once:

     * the chart marked a settle deadline on a DISPUTED claim, which the ladder
       drops on purpose — it is the date an undisputed answer would settle on,
       and the realm keeps publishing it after a dispute takes over;
     * "opened" on a synthesized chart was the SAMPLE WINDOW's left edge, which
       demoSeries picks as now minus a randomised week or two. It had been the
       wrong label all along and only became visible when a hover made it say
       a date, four days off what the ladder said.

   Both were invisible while the markers had nothing but a block height in a
   native tooltip. */
{
  const DAY=86400;
  const TL={ opened:{t:1600000000,h:1000}, answered:{t:1600000000+1500*DAY,h:3000},
             now:{t:1600000000+1800*DAY,h:5000} };
  const NOWH=5000, SER={pts:[[4900,60],[4990,64]], firstH:4900};
  const marks = h => (( h.match(/data-hovev="([^"]*)"/)||["",""])[1])
    .split(";").filter(Boolean).map(q=>{ const i=q.indexOf(","), j=q.indexOf(",",i+1);
      return { t:+q.slice(i+1,j), label:q.slice(j+1) }; });
  const day = t => stampDate(t);
  const base = {title:"T", yesStake:10, noStake:3, answer:0, yesConv:10, noConv:3};

  LIVE=true;
  // The ladder's settle row comes from the TIMELINE's settle entry, which
  // clock.gno emits only while an answer is standing undisputed — the same
  // condition the chart now gates its marker on. Both need it to compare.
  const TLA = Object.assign({}, TL, {settle:{t:TL.now.t+2000*5, h:NOWH+2000}});
  const ans = Object.assign({}, base, {statusText:"answered", phase:"answered", settleAt:NOWH+2000});
  const dis = Object.assign({}, base, {statusText:"disputed", phase:"disputed",
                                       settleAt:NOWH+2000, round:1, voteEndsAt:NOWH+4000});
  const mAns = marks(signalChart("orem",9,ans,NOWH,SER,TLA));
  const mDis = marks(signalChart("orem",9,dis,NOWH,SER,TL));
  LIVE=false;
  const lAns = resolutionLadder(ans, NOWH, TLA, false, false);
  const lDis = resolutionLadder(dis, NOWH, TL, false, false);

  ok("P8h an answered claim marks its settle deadline, and the ladder rows it",
     mAns.some(m=>m.label==="settle deadline") && lAns.includes("settle deadline"));
  ok("P8h a disputed claim marks neither — the deadline stopped being the clock",
     !mDis.some(m=>m.label==="settle deadline") && !lDis.includes("settle deadline"));
  ok("P8h ...and it still marks what IS its clock", mDis.some(m=>m.label==="vote closes"));
  // The day each names for the same event.
  const mNow = mAns.find(m=>m.label==="now");
  ok("P8h the chart's now and the ladder's now are the same day",
     !!mNow && lAns.includes(day(mNow.t)));
  const mAnsE = mAns.find(m=>m.label.indexOf("answered")===0);
  ok("P8h ...and so is the answer", !!mAnsE && day(mAnsE.t)===day(TL.answered.t));

  // A synthesized chart never calls its window's edge the claim's opening.
  LIVE=false;
  const synth = marks(signalChart("orem",4,DEMO.claims["orem/4"],NOW,null,
                                  parseTimeline(DEMO.claims["orem/4"].timeline)));
  ok("P8h a synthesized window says window start, not opened",
     synth.some(m=>m.label==="window start"));
  const op = synth.find(m=>m.label==="opened");
  const tl4 = parseTimeline(DEMO.claims["orem/4"].timeline);
  ok("P8h ...and any opened mark it does draw is the chain's own opening",
     !op || (tl4 && tl4.opened && day(op.t)===day(tl4.opened.t)));
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
/* THE CONVICTION CHIP CARRIES ITS UNIT ONCE. It read
   ccText(...).replace(/ [A-Z:]+$/, "") to drop the first symbol so the pair
   could share one at the end — and in MICRO units the text is
   "3,718 µKOURT:COVID", where the space sits before the µ and µ is not [A-Z:],
   so the regex matched nothing and the symbol stayed. The chip then printed the
   unit TWICE in one line, once as plain text and once as the gold bar, which is
   how it was spotted. Taken from ccFigure now, so there is nothing to strip. */
{
  const bare = h => String(h).replace(/<[^>]*>/g, "");
  const chip = (a, b) => bare(chartChips({convYes:a, convNo:b}, "covid"));

  const micro = chip(3718, 3225);
  ok("both figures in micro share one unit", /conviction 3,718 \/ 3,225 µ/.test(micro));
  ok("...and the unit is not printed twice", (micro.match(/OURT:COVID|Kourt:COVID/gi) || []).length === 1);

  const whole = chip(17_000_000, 15_000_000);
  ok("both figures whole share one unit", /conviction 17\.0 \/ 15\.0 /.test(whole));
  ok("...once", (whole.match(/OURT:COVID|Kourt:COVID/gi) || []).length === 1);

  /* MIXED UNITS GET TWO SYMBOLS, deliberately. "3,718 / 15.0 µKOURT:COVID"
     would put a micro figure and a whole one under one micro label — a wrong
     number rather than a terse one. */
  const mixed = chip(3718, 15_000_000);
  ok("a micro figure beside a whole one keeps its own unit",
     (mixed.match(/OURT:COVID|Kourt:COVID/gi) || []).length === 2);
  /* ASSERTED AGAINST CODE, NOT PROSE. Written against the raw source first, and
     it failed on the COMMENT beside the fix, which quotes the regex it replaced
     — the one place that pattern is worth keeping. The repo's own stripper is
     what tells the two apart. */
  {
    const { stripHtml } = require("../../scripts/strip-comments.js");
    const code = stripHtml(src).out;   // stripHtml, not stripJs: this is the page, not a script file
    ok("...and no regex strip survives in the code",
       !/replace\(\/ \[A-Z:\]\+\$\//.test(code));
    ok("...the figure comes from ccFigure instead", /ccFigure\(d\.convYes\)/.test(code));
  }
}

/* THE CHIP BORDER IS A DIRECT-CHILD RULE. `.chartchips span` styled every
   nested span, so once the mark became two spans each chip drew a box around
   "Kourt" and another around the court's name, with 7px of padding on each —
   which pushed the row out past its own container. Measured before the fix:
   nested bordered spans, chips wider than the row. */
ok("only a chip itself is boxed, not the spans inside it",
   /\.chartchips > span\{/.test(src) && !/\.chartchips span\{/.test(src));
/* THE SIDE'S NAME SITS IN A HAIRLINE OVAL, the gold bar's treatment with the
   corners taken all the way round.
   ROUNDED BY OVER-LARGE RADIUS, not by a measured one: any radius past half the
   height renders as a semicircular cap, so 999px says "fully rounded" and stays
   right when the font size or padding changes. A literal like 8px would look
   correct today and square off the moment the row grew.
   currentColor, NOT a token, so the border inherits --yes on one side and --no
   on the other from the .y/.n wrappers — one rule for both ovals, and a theme
   that moves either colour moves its oval with it. Pinned because a token here
   would give both sides the same border and quietly lose the distinction. */
ok("the side's name is wrapped for its own oval",
   src.includes('<b><span class="sidetag">YES</span> ${py.toFixed(1)}%</b>')
   && src.includes('<b><span class="sidetag">NO</span> ${pn.toFixed(1)}%</b>'));
ok("...as a hairline, fully rounded",
   /^\.sidetag\{[^}]*border:1px solid currentColor;[\s\S]{0,40}border-radius:999px/m.test(src));
ok("...taking its colour from the side, not a fixed token",
   !/^\.sidetag\{[^}]*border:1px solid var\(/m.test(src));
/* THE PERCENTAGE STAYS OUTSIDE IT. That figure changes on every read; the side
   is the label. A box around both reads as a control rather than a result. */
ok("...with the percentage outside the oval",
   !/class="sidetag">YES \$\{py/.test(src) && !/class="sidetag">NO \$\{pn/.test(src));

/* INLINE-BLOCK IS LOAD-BEARING, NOT TIDINESS. Reported as: "the top right and
   bottom left corners are square". An inline box that breaks across lines has
   its decoration sliced at the break — box-decoration-break defaults to slice —
   so the fragment before the break loses its right corners and the one after
   loses its left. Seen as one shape, that is a fully-rounded element with two
   square corners on one diagonal, which is the report exactly.
   IT DOES NOT REPRODUCE IN CHROMIUM and this pin does not claim it did: the
   computed radius is 999px on all four corners, an 8x render shows a clean
   stadium, and a device-pixel map of the real page is symmetric. white-space
   denies a break inside "YES", so Chromium cannot slice it. The declaration
   makes the failure unrepresentable rather than merely unreachable, and it is
   pinned so that dropping back to inline is a decision. */
ok("the oval is a block, so no engine can slice it across a line",
   /^\.sidetag\{[^}]*display:inline-block/m.test(src));
ok("...and still refuses to break inside the side's name",
   /^\.sidetag\{[^}]*white-space:nowrap/m.test(src));
/* AND IT PAYS FOR ITSELF. An inline-block's content area is its LINE HEIGHT,
   where an inline box's is the font's em box, so the display change alone grew
   the tag 17px -> 21.66px and the 320px claim embed 500px -> 503px, failing
   embed_layout.js. line-height:1 reproduces the inline geometry: measured at
   both #/embed/orem/1 and #/c/orem/3, scrollHeight and the .sbout row match the
   inline version exactly. The two declarations only work as a pair, so dropping
   this one silently re-breaks a check in a different file. */
ok("...at no cost to the line it sits in",
   /^\.sidetag\{[^}]*line-height:1;/m.test(src));

/* THE BALLOT QUESTION WEARS THE SAME MARK. Asked for alongside the signal bar:
   "also in the text 'Overturn the YES answer?'". It was a bare <b>.
   WEIGHT AND MARGIN STAY BAR-ONLY. The tag in the bar sits beside a percentage
   and needs a gap; the one in the <h3> does not. And the bar pins 600, which
   inside an already-bold heading would render the named side LIGHTER than the
   sentence around it — so the weight cannot live on the shared rule. */
ok("the ballot question names the side in the same oval",
   src.includes('Overturn the <span class="sidetag vtag ${ansSide === "NO" ? "n" : "y"}">${ansSide}</span> answer?'));
ok("...and no longer in a bare bold", !/Overturn the <b>\$\{ansSide\}<\/b>/.test(src));
ok("the gap and the weight are the signal bar's alone, not the shared rule",
   /^\.sbout \.sidetag\{margin-right:2px; font-weight:600\}/m.test(src)
   && !/^\.sidetag\{[^}]*font-weight/m.test(src));


console.log(fail? fail+" FAILURES":"ok all "+"chart pins");
DONE = true;
