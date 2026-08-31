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
// hundred, so it can afford the courses of the plinth and the air around them —
// same seat, drawn with room.
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

// The seat, at card scale: the same twelve rectangles the mark is made of,
// scaled up and given the space to read as stone rather than as an icon.
const SEAT = `
<svg viewBox="3 0 94 100" width="330" height="351" aria-hidden="true" fill="#12100c">
  <rect x="17" y="0" width="5" height="66"/><rect x="24" y="0" width="5" height="66"/>
  <rect x="31" y="0" width="5" height="66"/><rect x="64" y="0" width="5" height="66"/>
  <rect x="71" y="0" width="5" height="66"/><rect x="78" y="0" width="5" height="66"/>
  <rect x="36" y="8" width="28" height="58"/>
  <rect x="12" y="66" width="76" height="10"/>
  <rect x="20" y="76" width="10" height="11"/><rect x="70" y="76" width="10" height="11"/>
  <rect x="8" y="87" width="84" height="6"/>
  <rect x="3" y="93" width="94" height="7"/>
  <g fill="#9a6f12">
    <rect x="17" y="0" width="5" height="3.4"/><rect x="24" y="0" width="5" height="3.4"/>
    <rect x="31" y="0" width="5" height="3.4"/><rect x="64" y="0" width="5" height="3.4"/>
    <rect x="71" y="0" width="5" height="3.4"/><rect x="78" y="0" width="5" height="3.4"/>
    <rect x="36" y="8" width="28" height="3.4"/>
    <rect x="12" y="66" width="76" height="2.6"/>
    <rect x="8" y="87" width="84" height="2"/><rect x="3" y="93" width="94" height="2.2"/>
  </g>
</svg>`;

// No webfont: a card that waits on a font download renders in a fallback and
// ships that. Georgia and the platform mono are on every machine that runs this.
const CARD = `<!doctype html><meta charset="utf-8"><style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{width:1200px;height:630px;background:#f7f4ec;color:#12100c;overflow:hidden;
       display:flex;align-items:center;gap:26px;padding:0 78px 0 62px;
       font-family:Georgia,"Times New Roman",serif}
  .fig{flex:none;margin-top:-14px}
  .txt{flex:1;min-width:0}
  h1{font-size:132px;line-height:.92;letter-spacing:-.03em;font-weight:600}
  .rule{height:3px;background:#12100c;margin:26px 0 24px;width:190px}
  p{font-size:31px;line-height:1.34;color:#3a352c;max-width:23ch}
  .foot{margin-top:34px;display:flex;align-items:baseline;gap:14px;
        font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:21px;
        letter-spacing:.16em;text-transform:uppercase;color:#7d766a}
  .said{font-family:Georgia,serif;font-size:25px;letter-spacing:0;text-transform:none;
        color:#12100c;font-style:italic}
</style>
<div class="fig">${SEAT}</div>
<div class="txt">
  <h1>Kourt</h1>
  <div class="rule"></div>
  <p>Let Truth be told.</p>
  <div class="foot"><span>kourt.xyz</span><span class="said">The seat is empty.</span></div>
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
