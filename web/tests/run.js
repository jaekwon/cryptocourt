#!/usr/bin/env node
// Run every harness in this directory and report one line each.
//
// WHY THIS EXISTS. These files were written during the website iteration and
// lived in a session scratch directory — outside the repo, unenumerated, and
// runnable only by remembering their names. Two of them had been broken for
// fourteen rounds by a rename nobody re-ran them against, and ten more broke
// in one commit that was reported green because four were run by hand. A suite
// you cannot enumerate is a suite you are not running.
//
// Each harness is a standalone node script that reads ../index.html, evaluates
// slices of its source, and prints "ALL PASS" or "N FAILURES".
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const dir = __dirname;
const files = fs.readdirSync(dir).filter(f => f.endsWith("_test.js")).sort();
if (!files.length) {
  console.error("web/tests: no *_test.js found — the suite cannot be empty");
  process.exit(1);
}

let failed = 0;
for (const f of files) {
  const r = spawnSync(process.execPath, [path.join(dir, f)], {encoding: "utf8"});
  const out = (r.stdout || "") + (r.stderr || "");
  const ok = r.status === 0 && /ALL PASS/.test(out);
  if (!ok) {
    failed++;
    const why = (out.split("\n").find(l => /^FAIL|Error:/.test(l)) || "").trim();
    console.log(`FAIL  ${f}  ${why.slice(0, 90)}`);
  } else {
    const n = (out.match(/^ok:/gm) || []).length;
    console.log(`ok    ${f}  (${n} assertions)`);
  }
}
console.log(failed
  ? `\nweb-test: ${failed} of ${files.length} harnesses failing`
  : `\nweb-test: ${files.length} harnesses pass.`);
process.exit(failed ? 1 : 0);
