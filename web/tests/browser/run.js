#!/usr/bin/env node
// The browser-based half of the overlay's suite: checks that need real layout.
//
// Separate from ../run.js because these need puppeteer and a headless Chrome,
// which the pure-source harnesses do not. `make web-test` runs those and stays
// dependency-free; this runs only when a browser is actually available.
//
// WHAT IS HERE AND WHY IT EARNED ITS PLACE:
//
//   banner_layout.js   — measures real geometry at three widths. It caught a
//                        `grid-row:1/-1` that is meaningless without explicit
//                        rows, which had put the entire page body into column 1
//                        BELOW the sidebar (main.left=0, main.top=900) on every
//                        route. Reading the CSS did not catch it; measuring did.
//
//   embed_layout.js    — measures the embed routes at exactly the sizes the
//                        share snippet offers (400x400, 400x240, and 320 wide).
//                        An embed's whole promise is that it FITS inside someone
//                        else's page: no scrollbar, no chrome, and a ?theme= that
//                        really repaints. All four are layout facts, invisible to
//                        a source-reading harness.
//
//   tagrow_layout.js   — the utility row under a page title, on all four routes
//                        that use it. Every complaint about it was a computed-
//                        style or layout fact: a button inheriting the 15px body
//                        size instead of 12.5px, inline colours that made :hover
//                        unstylable, and a curator-supplied folder label that
//                        made the page scroll sideways at 390px.
//
//   route_crawl.js     — follows every internal link the overlay draws and holds
//                        the destination to what the link named. It exists for a
//                        bug that shipped: chain folders started nesting, the
//                        route kept resolving against the root array, and every
//                        chain subfolder answered "no such folder" while the
//                        court page linked to it. The source harnesses could not
//                        see it (two functions agreeing to disagree), the layout
//                        checks only measure routes they are handed, and reading
//                        the row's LABEL proves nothing — a link renders the same
//                        whether or not it opens. Note it checks BOTH halves:
//                        the first version only asked "does the page exist", and
//                        an armed run went green because the broken resolution
//                        landed on the WRONG folder rather than on none.
//
//   chat_all.js        — a WRAPPER, and the reason it is one. It runs the four
//                        chat harnesses: chat_page, chat_render, chat_live and
//                        chat_moderation (which skips itself, and says so, unless
//                        OLLAMA_LIVE=1). They sat here unregistered and therefore
//                        unrun, and two of their assertions had gone false in the
//                        meantime — the moniker maxlength after the limit moved to
//                        counting letters, and "blanking the field turns chat off"
//                        after `undefined` came to mean the default, which is ON.
//                        Both were caught the first time anything ran them.
//                        check-browser-checks-registered.py now fails `make check`
//                        if a harness here is reachable from no runner.
//
//   render_snapshot.js — captures the rendered text of 13 demo routes. Used to
//                        prove a refactor changes nothing: capture, refactor,
//                        capture, diff. It is how the DEMO split was shown to
//                        be behaviour-preserving across all 13 routes.
//                        Run directly; it prints JSON on stdout.
//
// Usage:  node web/tests/browser/run.js       (or `make web-visual`)
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

try {
  require.resolve("puppeteer");
} catch (e) {
  console.log("web-visual: puppeteer not installed - skipping browser checks");
  process.exit(0);
}

// Only the pass/fail checks run here. render_snapshot.js is a TOOL: it prints a
// snapshot rather than asserting, so running it in a gate would prove nothing.
// banner_layout.js went with the test-clock banner in f184247 — "every page
// renders as production, whatever the node's clock was told". Removed here too,
// because a runner that requires a harness nobody has fails for a reason that is
// not about the page.
/* RUN ONE OF THESE, OR ALL OF THEM. Each harness launches its own headless
   Chrome and drives real pages, so none is cheap and the total is around two
   minutes — measured: chat_all 34s, embed_layout 23s, rowscope_layout 23s,
   route_crawl 21s, tagrow_layout 14s.
   That is the right cost before a commit and the wrong one after every edit,
   where it means either waiting or (what actually happens) not running it and
   finding the layout bug from a screenshot three changes later. So a filter:
   ONLY=rowscope runs the one harness that covers what you just touched. It is a
   substring, matched against the file name.
   The default is still everything — a filter you have to remember to widen is a
   suite that quietly stops covering things. */
const ALL = ["embed_layout.js", "tagrow_layout.js", "route_crawl.js",
             "rowscope_layout.js", "map_draws.js", "map_type.js", "map_boing.js", "stone.js", "temple.js", "chat_all.js",
             // the artifact deploy.sh actually uploads, with its comments gone
             "stripped_boot.js"];
const only = (process.env.ONLY || process.argv.slice(2).join(",") || "").trim();
const CHECKS = only
  ? ALL.filter(f => only.split(",").some(k => k && f.includes(k.trim())))
  : ALL;
if(only && !CHECKS.length){
  console.log(`web-visual: ONLY="${only}" matched none of: ${ALL.join(" ")}`);
  process.exit(2);
}
let failed = 0;
for (const f of CHECKS) {
  const p = path.join(__dirname, f);
  if (!fs.existsSync(p)) { console.log(`FAIL  ${f}  missing`); failed++; continue; }
  const r = spawnSync(process.execPath, [p], {encoding: "utf8"});
  const out = (r.stdout || "") + (r.stderr || "");
  if (r.status === 0 && /ALL PASS/.test(out)) {
    // `^ok:` is a leaf harness's assertion; `^ok ` is a WRAPPER reporting one of
    // its children. Counting only the first printed "0 measurements" next to
    // chat_all.js, which had just run 157 of them — a number that invites exactly
    // the "this check is vacuous" reading this suite exists to make impossible.
    const n = (out.match(/^ok[: ]/gm) || []).length;
    console.log(`ok    ${f}  (${n} measurement${n === 1 ? "" : "s"})`);
  } else {
    failed++;
    // A REASON EVEN WHEN THERE IS NO FAIL LINE. A check that exits 0 without ever
    // printing ALL PASS fails here and used to do it in silence — "FAIL
    // chat_all.js" and nothing after, which reads as a crash rather than as a
    // wrapper that phrased its verdict differently. Which is exactly what it was.
    const why = (out.split("\n").find(l => /^FAIL|Error:/.test(l)) || "").trim().slice(0, 90)
      || (r.status === 0 ? "exited 0 but never printed ALL PASS" : `exited ${r.status}`);
    console.log(`FAIL  ${f}  ${why}`);
  }
}
console.log(failed ? `\nweb-visual: ${failed} failing`
  : `\nweb-visual: ${CHECKS.length} browser check(s) pass.`
    + (only? `  (filtered by ONLY="${only}" — ${ALL.length - CHECKS.length} not run)` : ""));
process.exit(failed ? 1 : 0);
