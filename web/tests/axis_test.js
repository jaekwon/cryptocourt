#!/usr/bin/env node
// THE CHART'S X-AXIS IS TIME, and on this chain that is not the same shape as
// block height.
//
// Reported on covid/19: "answered yes / disputed / now all bunched up... the
// time between the three nodes should be 2 days, but looks like 2 hours."
//
// The cause is a cadence the axis could not see. This chain walks 720 blocks a
// day; votingBlocks is 120,960. So a vote closing FIVE DAYS out sits 120,240
// blocks to the right, and laid out by height that one marker takes the whole
// width and crushes everything else against the left edge.
//
// Every number below is covid/19's own, read off the live chain rather than
// reasoned out — an earlier draft of this file invented plausible heights and
// asserted the flat-cadence error was "weeks" when on the real row it is two
// days. The realm's own reading is the only thing that pins this.
//
//   ClaimTimeline("covid",19) =>
//   opened:1786320000:104400;answered:1788220800:116640;settle:1788480000:168480;
//   dispute:1788307200:117360;voteclose:1788912000:238320;now:1788475403:118080;
//   testclock:209347200:118080
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
function slice(f,t){const a=src.indexOf(f);if(a<0)throw new Error("missing "+f);
  const b=src.indexOf(t,a);if(b<0)throw new Error("missing "+t);return src.slice(a,b);}

let code = '';
code += slice('const BLOCK_SECS','\n').replace('const ','var ') + '\n';
code += slice('function parseTimeline(','function resolutionLadder(');
code += slice('function heightDater(','/* WHAT HAS HAPPENED TO THIS CLAIM');
eval(code);

let fail = 0, n = 0;
// One `ok:` line per passing assertion — run.js counts those, and a harness that
// stays silent is reported as "0 assertions", which is indistinguishable from
// one that has been gutted.
const ok = (name,c) => { n++; if(c) console.log("ok:",name); else {fail++; console.log("FAIL:",name);} };
const near = (a,b,tol) => Math.abs(a-b) <= tol;

const RAW = "opened:1786320000:104400;answered:1788220800:116640;settle:1788480000:168480"
  + ";dispute:1788307200:117360;voteclose:1788912000:238320;now:1788475403:118080"
  + ";testclock:209347200:118080";
const TL = parseTimeline(RAW);
const zdt = heightDater(TL);
ok("the live timeline parses and dates", TL && typeof zdt === "function");

// ---- a published row is dated by its own stamp, never by a cadence ---------
for (const k of ["opened","answered","settle","dispute","voteclose","now"])
  ok(k+" dates to the stamp the realm wrote, not to an assumed cadence",
     near(zdt(TL[k].h), TL[k].t, 1));

// The two that were missing, and the error they caused. Stated as the gap
// between what the page showed and what the realm meant.
{
  const flat = TL.now.t + (TL.voteclose.h - TL.now.h) * BLOCK_SECS;
  const realHorizon = TL.voteclose.t - TL.now.t;              // ~5.05 days
  const shownHorizon = flat - TL.now.t;                        // ~6.96 days
  ok("the flat five-second assumption overstates the vote's horizon",
     shownHorizon > realHorizon);
  ok("...by about two days on a five-day window — a third too far",
     near(shownHorizon - realHorizon, 164603, 60));
}
// settle was missing for the same reason and is drawn on any UNDISPUTED claim.
{
  const flat = TL.now.t + (TL.settle.h - TL.now.h) * BLOCK_SECS;
  ok("a settle deadline ~1h away would have been drawn ~3 days out",
     flat - TL.settle.t > 2*86400);
  ok("...and is now placed at its own stamp instead",
     near(zdt(TL.settle.h), TL.settle.t, 1));
}
// testclock carries two SKEWS, not a moment. On covid/19 the height skew equals
// `now`'s height — the whole height was fabricated — so the row is deduped away
// and excluding it changes nothing there. That coincidence is the trap: on a
// chain whose test clock was armed AFTER real blocks were mined the skew is a
// smaller, different height, and the row lands as a live anchor dated 209347200,
// which is 1976. So the case worth pinning is the one where they differ.
{
  const armedLater = parseTimeline(
    "opened:1786320000:104400;answered:1788220800:116640;now:1788475403:118080"
    + ";testclock:209347200:50000");
  const z = heightDater(armedLater);
  ok("a testclock row at its own height still never anchors",
     near(z(TL.now.h), TL.now.t, 1));
  // A height below the first real event: dated by the opened→answered rate it
  // must stay in the same era. Anchored, testclock drags it back to the 1980s.
  ok("...and does not drag neighbouring heights back to 1976",
     z(60000) > 1_700_000_000);
}

// ---- and the spacing a reader compares against the dates -------------------
// What is asserted is the RATIO, because that is what the eye measures.
{
  const span = zdt(TL.voteclose.h) - zdt(TL.answered.h);
  const frac = h => (zdt(h) - zdt(TL.answered.h)) / span;
  ok("disputed sits an eighth of the way across, one day into eight",
     near(frac(TL.dispute.h), 0.125, 0.01));
  ok("now sits over a third of the way across, three days into eight",
     near(frac(TL.now.h), 0.368, 0.01));
  // The bug, written as the thing that must not come back.
  const hspan = TL.voteclose.h - TL.answered.h;
  ok("...where laid out by HEIGHT all three would bunch inside 2% of the width",
     (TL.now.h - TL.answered.h) / hspan < 0.02);
}

// ---- a claim with no stamps still gets the old behaviour -------------------
{
  // A pre-upgrade claim carries zero stamps. There is nothing to date it by, and
  // the honest answer is to say so rather than to invent a cadence — the caller
  // then falls back to plotting raw heights.
  const bare = parseTimeline("opened:0:100;now:0:200");
  ok("a pre-stamp timeline dates nothing at all", heightDater(bare) === null);
  const one = parseTimeline("now:1788475403:118080");
  const z1 = heightDater(one);
  ok("a single anchor falls back to the nominal interval",
     near(z1(118080+100), 1788475403 + 100*BLOCK_SECS, 1));
}

console.log(fail ? fail+" FAILURES" : "ALL PASS ("+n+" assertions)");
process.exit(fail ? 1 : 0);
