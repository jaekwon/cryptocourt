#!/usr/bin/env node
// THE PARTICIPANT-ONLY WEEK, AS THE PAGE DECIDES IT.
//
// Crystallize is participant-only for a week after the verdict, and the page
// greys "Open the rewards" while that week runs. It decided in BLOCKS — 120,960
// of them — which is a week only while the chain holds 5s a block. kourt-1 does
// not: claim covid/10 was settled 7 Apr 2022 and read 53,280 blocks of that
// window in December 2026, so the page told a reader the first week was still
// running 1,713 days later while crystallize.gno would have let them through.
//
// A page that greys a control the chain would accept is the reopen link's bug
// on a third surface, and the fix is the same: read the moment, not the height.
const { slice } = require("./srcslice");
const V = s => s.replace(/^const /gm, 'var ');
eval(V(slice('const BLOCK_SECS =', '\n')));
eval(V(slice('const FINALIZE_GRACE =', '\n')));
eval(slice('function finalizeGraceOver(', '\nasync function fillWithdrawSides('));

let fail = 0;
const ok = (n, c) => { if (!c) { fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

const DAY = 86400, WEEK_SECS = 7 * DAY;

// ---- the reported claim, with its real numbers ---------------------------
{
  const vT = 1649289600, nowT = 1797292800;   // 7 Apr 2022 -> 15 Dec 2026
  const vAt = 71280,     nowH = 124560;       // 53,280 blocks of 120,960
  ok("covid/10: the week is over on the clock, 1,713 days later",
     finalizeGraceOver(vT, nowT, vAt, nowH) === true);
  ok("covid/10: ...and the blocks alone would still say it is running",
     (nowH - vAt) < FINALIZE_GRACE);
}

// ---- the boundary, to the second -----------------------------------------
{
  const vT = 1_700_000_000, vAt = 1000;
  ok("one second short of the week, it is still running",
     finalizeGraceOver(vT, vT + WEEK_SECS - 1, vAt, vAt) === false);
  ok("on the second itself, it is over",
     finalizeGraceOver(vT, vT + WEEK_SECS, vAt, vAt) === true);
}

// ---- a verdict from before the stamps keeps its block window -------------
{
  const vAt = 1000;
  ok("no stamps: one block short, still running",
     finalizeGraceOver(0, 0, vAt, vAt + FINALIZE_GRACE - 1) === false);
  ok("no stamps: on the block, over",
     finalizeGraceOver(0, 0, vAt, vAt + FINALIZE_GRACE) === true);
  ok("no stamps and no heights: not over, so the note stands",
     finalizeGraceOver(0, 0, null, null) === false);
}

// ---- the stamps WIN over the heights, which is the whole change ----------
{
  ok("stamps decide even when the heights disagree",
     finalizeGraceOver(1_700_000_000, 1_700_000_000 + WEEK_SECS, 1000, 1000) === true);
}

if (!fail) console.log("ALL PASS");
process.exit(fail ? 1 : 0);
