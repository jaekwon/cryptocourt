// The link preview: web/og.png, 1200x630.
//
// WHY A SCRIPT AND NOT A CHECKED-IN DRAWING. og.png is the one binary in this
// repo, and a binary nobody can regenerate is a binary nobody can correct — the
// next person to change the wordmark would have had to open an image editor and
// match a font by eye. Everything here is text: run it and the file comes back
// byte-for-byte the same, so `--check` can verify the shipped card is the card
// this source describes.
//
// WHY THE CARD IS NOT JUST THE FAVICON SCALED UP. The mark is twelve rectangles
// because it has to survive 16px. A card is 1200 wide and shown at a few
// hundred, so it can afford the courses of the plinth and the air around them.
//
// WHY IT IS THE GRAPH AND NOT THE SEAT ANY MORE. Reported as "when sharing, the
// graph doesn't show — I want the share to be more like the graph". Every link
// ever pasted previewed as furniture: the seat said what a court IS, and the
// map says what this one DOES, which is the thing worth a picture.
//
// WHY IT IS DRAWN HERE AND NOT SCREENSHOT FROM THE MAP, which was the first
// version and worked: rendering web/index.html would tie this file's sha to the
// whole page and to the sample court's data, so any unrelated edit would fail
// `--check` and block a deploy as "stale". It would also put the sample court's
// claims — a mayor, a rezoning, a bridge inspection — legibly into the one
// picture the world sees, where a reader has no way to know they are specimens.
// So the nodes carry ruled lines where their text would be. The shape is the
// claim; the words are not this card's to make.
//
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const OUT = path.join(__dirname, "..", "web", "og.png");
const CHECK = process.argv.includes("--check");

let puppeteer;
try { puppeteer = require("puppeteer"); }
catch (_) {
  console.log("make-og-card: puppeteer not installed — leaving web/og.png as it is");
  process.exit(0);
}

// The court, still twelve rectangles, but small now: it is a node in the graph
// rather than the subject of the card.
const SEAT = `
<svg viewBox="3 0 94 100" width="52" height="55" aria-hidden="true" fill="#c9cef0">
  <rect x="17" y="0" width="5" height="66"/><rect x="24" y="0" width="5" height="66"/>
  <rect x="31" y="0" width="5" height="66"/><rect x="64" y="0" width="5" height="66"/>
  <rect x="71" y="0" width="5" height="66"/><rect x="78" y="0" width="5" height="66"/>
  <rect x="36" y="8" width="28" height="58"/>
  <rect x="12" y="66" width="76" height="10"/>
  <rect x="20" y="76" width="10" height="11"/><rect x="70" y="76" width="10" height="11"/>
  <rect x="8" y="87" width="84" height="6"/>
  <rect x="3" y="93" width="94" height="7"/>
  <g fill="#b8862b">
    <rect x="17" y="0" width="5" height="3.4"/><rect x="24" y="0" width="5" height="3.4"/>
    <rect x="31" y="0" width="5" height="3.4"/><rect x="64" y="0" width="5" height="3.4"/>
    <rect x="71" y="0" width="5" height="3.4"/><rect x="78" y="0" width="5" height="3.4"/>
    <rect x="36" y="8" width="28" height="3.4"/>
    <rect x="12" y="66" width="76" height="2.6"/>
    <rect x="8" y="87" width="84" height="2"/><rect x="3" y="93" width="94" height="2.2"/>
  </g>
</svg>`;

// THE GRAPH. Fixed coordinates and no randomness, because `--check` compares a
// sha: the same source must draw the same pixels every time.
// The vocabulary is the map's own — a court at the middle, folders wired to it,
// claims filed under those, and the four relation strokes the legend names.
const N = (x, y, w, h, kind) => ({x, y, w, h, kind});
const NODES = [
  N(628, 286, 176, 62, "court"),
  N(404, 214, 132, 40, "folder"), N(836, 232, 132, 40, "folder"),
  N(596, 430, 132, 40, "folder"),
  N(262, 96, 210, 62, "claim"),  N(540, 78, 210, 62, "claim"),
  N(884, 92, 210, 62, "claim"),  N(196, 330, 210, 62, "claim"),
  N(892, 386, 210, 62, "claim"), N(430, 512, 210, 62, "claim"),
  N(742, 520, 210, 62, "claim"),
];
// from, to, stroke — the legend's four, in the legend's colours
const EDGES = [
  [1, 0, "filed"], [2, 0, "filed"], [3, 0, "filed"],
  [4, 1, "filed"], [5, 1, "filed"], [6, 2, "filed"],
  [7, 1, "filed"], [8, 2, "filed"], [9, 3, "filed"], [10, 3, "filed"],
  [4, 7, "supports"], [10, 8, "contradicts"], [5, 6, "supersedes"],
];
const mid = n => [n.x + n.w / 2, n.y + n.h / 2];
const STROKE = {
  filed:       'stroke="#5a63a0" stroke-width="2"',
  supports:    'stroke="#4ea88a" stroke-width="2" stroke-dasharray="9 7"',
  contradicts: 'stroke="#c96a5a" stroke-width="2" stroke-dasharray="9 7"',
  supersedes:  'stroke="#7f869c" stroke-width="2" stroke-dasharray="2 6"',
};
const FILL = {court: "#aab2e4", folder: "#1e2647", claim: "#151a24"};
const EDGE = {court: "#c9cef0", folder: "#4d5da8", claim: "#39404f"};

// Ruled lines where a claim's sentence would be. Two per node, the second
// short, which is what a wrapped title looks like at this size.
const lines = n => n.kind !== "claim" ? "" :
  `<rect x="${n.x + 14}" y="${n.y + 20}" width="${n.w - 46}" height="6" rx="3" fill="#565e6e"/>` +
  `<rect x="${n.x + 14}" y="${n.y + 34}" width="${(n.w - 46) * 0.62}" height="6" rx="3" fill="#3f4655"/>`;
// A folder's own two rules, shorter and cooler.
const frules = n => n.kind !== "folder" ? "" :
  `<rect x="${n.x + 13}" y="${n.y + 15}" width="${n.w - 40}" height="5" rx="2.5" fill="#8792d8"/>` +
  `<rect x="${n.x + 13}" y="${n.y + 26}" width="${(n.w - 40) * 0.5}" height="5" rx="2.5" fill="#5b67ae"/>`;
// The settled marks: one YES, one NO, the rest unanswered.
const CHIP = {5: ["#5fbf9f", "YES"], 8: ["#5fbf9f", "YES"], 10: ["#d9806f", "NO"]};
const chip = (n, i) => {
  const c = CHIP[i];
  if (!c) return `<circle cx="${n.x + n.w - 18}" cy="${n.y + n.h - 15}" r="7" fill="none" stroke="#39404f" stroke-width="2"/>`;
  return `<rect x="${n.x + n.w - 56}" y="${n.y + n.h - 25}" width="42" height="20" rx="10" fill="none" stroke="${c[0]}" stroke-width="2"/>`
       + `<text x="${n.x + n.w - 35}" y="${n.y + n.h - 11}" text-anchor="middle" font-family="ui-monospace,Menlo,monospace" font-size="12" fill="${c[0]}">${c[1]}</text>`;
};
const GRAPH = `
<svg viewBox="0 0 1200 630" width="1200" height="630" aria-hidden="true">
  ${EDGES.map(([a, b, k]) => {
    const [x1, y1] = mid(NODES[a]), [x2, y2] = mid(NODES[b]);
    return `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" ${STROKE[k]} opacity=".72"/>`;
  }).join("")}
  ${NODES.map((n, i) => {
    const r = n.kind === "court" ? 10 : 8;
    return `<rect x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" rx="${r}"`
         + ` fill="${FILL[n.kind]}" stroke="${EDGE[n.kind]}" stroke-width="${n.kind === "court" ? 2 : 1.5}"/>`
         + lines(n) + frules(n) + (n.kind === "claim" ? chip(n, i) : "");
  }).join("")}
</svg>`;

// No webfont: a card that waits on a font download renders in a fallback and
// ships that. Georgia and the platform mono are on every machine that runs this.
const CARD = `<!doctype html><meta charset="utf-8"><style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{width:1200px;height:630px;background:#0b0e14;color:#f6f3ec;overflow:hidden;
       position:relative;font-family:Georgia,"Times New Roman",serif}
  .graph{position:absolute;inset:0}
  /* ON TOP OF THE COURT NODE, not inside it, which is where the map puts it —
     the first pass had it hanging off the box's left edge. The court node is
     176 wide at x=628, so 690 centres a 52-wide mark over it, and 227 sets it
     just clear of the box's top at y=286. */
  .seat{position:absolute;left:690px;top:227px}
  /* The wash is what lets a serif sit on a drawing without either losing. It
     clears the left third and is gone by the middle, so the graph still runs
     under the words and out of frame on the right. */
  .wash{position:absolute;inset:0;
        background:linear-gradient(90deg,rgba(11,14,20,.97) 0%,rgba(11,14,20,.93) 30%,
          rgba(11,14,20,.55) 48%,rgba(11,14,20,.12) 70%,rgba(11,14,20,0) 86%)}
  .txt{position:absolute;left:74px;top:196px;width:520px}
  h1{font-size:132px;line-height:.92;letter-spacing:-.03em;font-weight:600}
  .rule{height:4px;background:#b8862b;margin:26px 0 24px;width:190px}
  p{font-size:31px;line-height:1.34;color:#cfcabf}
</style>
<div class="graph">${GRAPH}</div>
<div class="seat">${SEAT}</div>
<div class="wash"></div>
<div class="txt">
  <h1>Kourt</h1>
  <div class="rule"></div>
  <p>Let Truth be told.</p>
</div>`;

(async () => {
  const browser = await puppeteer.launch({ headless: "new" });
  const page = await browser.newPage();
  const errs = [];
  page.on("pageerror", (e) => errs.push(e.message));
  // deviceScaleFactor 1: 1200x630 is the size the platforms want, and a 2x file
  // is four times the bytes for a picture nobody zooms.
  await page.setViewport({ width: 1200, height: 630, deviceScaleFactor: 1 });
  await page.setContent(CARD, { waitUntil: "load" });
  await page.evaluateHandle("document.fonts.ready");
  const buf = await page.screenshot({ type: "png" });
  await browser.close();
  if (errs.length) { console.error("make-og-card: page errors:", errs); process.exit(1); }

  const sha = crypto.createHash("sha256").update(buf).digest("hex");
  const had = fs.existsSync(OUT) ? fs.readFileSync(OUT) : null;
  const hadSha = had && crypto.createHash("sha256").update(had).digest("hex");

  if (CHECK) {
    if (!had) { console.error("make-og-card: web/og.png is missing"); process.exit(1); }
    if (hadSha !== sha) {
      console.error(`make-og-card: web/og.png is stale\n  in tree ${hadSha.slice(0,16)}…`
                  + `\n  source  ${sha.slice(0,16)}…\n  run: node scripts/make-og-card.js`);
      process.exit(1);
    }
    console.log(`make-og-card: web/og.png matches its source (sha ${sha.slice(0,16)}…)`);
    return;
  }
  fs.writeFileSync(OUT, buf);
  console.log(`make-og-card: wrote web/og.png — ${buf.length} bytes, 1200x630, `
            + `sha ${sha.slice(0,16)}…${hadSha === sha ? " (unchanged)" : ""}`);
})();
