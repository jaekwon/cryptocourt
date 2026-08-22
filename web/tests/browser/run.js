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
const CHECKS = ["banner_layout.js", "embed_layout.js", "tagrow_layout.js", "route_crawl.js",
                "chat_all.js"];
let failed = 0;
for (const f of CHECKS) {
  const p = path.join(__dirname, f);
  if (!fs.existsSync(p)) { console.log(`FAIL  ${f}  missing`); failed++; continue; }
  const r = spawnSync(process.execPath, [p], {encoding: "utf8"});
  const out = (r.stdout || "") + (r.stderr || "");
  if (r.status === 0 && /ALL PASS/.test(out)) {
    console.log(`ok    ${f}  (${(out.match(/^ok:/gm) || []).length} measurements)`);
  } else {
    failed++;
    console.log(`FAIL  ${f}  ${(out.split("\n").find(l => /^FAIL|Error:/.test(l)) || "").trim().slice(0, 90)}`);
  }
}
console.log(failed ? `\nweb-visual: ${failed} failing` : `\nweb-visual: ${CHECKS.length} browser check(s) pass.`);
process.exit(failed ? 1 : 0);
