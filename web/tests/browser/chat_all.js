// Runs the chat panel's browser harnesses as one check.
//
// WHY THIS FILE EXISTS. web/tests/browser/run.js has CHECKS = ["banner_layout.js"], so the four
// chat harnesses beside it were never executed by `make web-visual` — they only ran when somebody
// invoked them by hand. That is not a hypothetical cost: chat_render.js was asserting that the
// moniker input's `maxlength` equals the server's limit, which stopped being true when the limit
// moved to counting LETTERS and the attribute became a looser paste bound. The assertion was wrong
// for two commits and nothing said so.
//
// run.js is not mine to edit while it is uncommitted, so this wraps the four instead: one entry
// added to CHECKS later picks all of them up, and no in-flight file needs changing now.
//
// chat_moderation.js skips itself without OLLAMA_LIVE=1 and reports ALL PASS, which is the same
// contract the Go live tests use — a skip is not a pass, but it is not a failure either, and it
// says which it is on the way past.
const {spawnSync} = require("child_process");
const path = require("path");
const fs = require("fs");

const CHECKS = ["chat_page.js", "chat_render.js", "chat_live.js", "chat_moderation.js"];

let failed = 0;
for (const f of CHECKS) {
  const p = path.join(__dirname, f);
  if (!fs.existsSync(p)) {
    console.log(`FAIL  ${f}  missing`);
    failed++;
    continue;
  }
  const r = spawnSync(process.execPath, [p], {encoding: "utf8"});
  const out = (r.stdout || "") + (r.stderr || "");
  const skipped = /skipping/.test(out);
  if (r.status === 0 && /ALL PASS/.test(out)) {
    const n = (out.match(/^ok:/gm) || []).length;
    console.log(`ok    ${f}  (${skipped ? "skipped — needs OLLAMA_LIVE=1" : n + " checks"})`);
  } else {
    failed++;
    const why = (out.split("\n").find(l => /^FAIL|Error:/.test(l)) || "").trim().slice(0, 90);
    console.log(`FAIL  ${f}  ${why}`);
  }
}
console.log(failed ? `\nchat-visual: ${failed} failing` : `\nchat-visual: ${CHECKS.length} browser check(s) pass.`);
process.exit(failed ? 1 : 0);
