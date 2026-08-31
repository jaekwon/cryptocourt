// The link preview: web/og.png, 1200x630.
//
// WHY A SCRIPT AND NOT A CHECKED-IN DRAWING. og.png is the one binary in this
// repo, and a binary nobody can regenerate is a binary nobody can correct — the
// next person to change the wordmark would have had to open an image editor and
// match a font by eye. Everything here is text: run it and the file comes back
// byte-for-byte the same, so `--check` can verify the shipped card is the card
// this source describes.
//
// WHY THE FULL FIGURE. The rail's mark drops everything below the moustache
// because it renders at 30px. A card is 1200 wide and shown at a few hundred:
// there is room for the glass, which is the whole joke, so the card carries the
// figure the mark is an abbreviation of.
//
//   node scripts/make-og-card.js            write web/og.png
//   node scripts/make-og-card.js --check    fail if web/og.png is out of date
//
// Needs puppeteer, like the browser harnesses. With no node or no puppeteer this
// exits 0 and says so: the card in the tree is already correct, and a laptop
// without a headless Chrome must not fail the build over a file it cannot draw.
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

// The figure, at card scale. Same character as the rail's mark; the mark is this
// drawing with the head, glass and collar taken off. Solid fills are safe here
// because a card has one fixed ground, unlike the page.
const SIR = `
<svg viewBox="20 8 220 226" width="430" height="442" aria-hidden="true">
  <g fill="none" stroke="#12100c" stroke-width="7" stroke-linecap="round" stroke-linejoin="round">
    <path fill="#12100c" stroke="none" d="M94 20 L174 20 L174 72 L94 72 Z"/>
    <path fill="#12100c" stroke="none" d="M72 74 C102 66 166 66 196 74 C166 82 102 82 72 74 Z"/>
    <path d="M94 58 L174 58" stroke="#f7f4ec" stroke-width="6"/>
    <path d="M98 76 C98 120 108 150 134 155 C160 150 170 120 170 76"/>
    <path d="M108 96 C116 90 126 90 132 95"/>
    <circle cx="120" cy="108" r="4.5" fill="#12100c" stroke="none"/>
    <circle cx="156" cy="106" r="19"/>
    <circle cx="156" cy="106" r="4.5" fill="#12100c" stroke="none"/>
    <path d="M172 116 C186 132 184 156 164 166" stroke-width="5"/>
    <path d="M138 112 C134 122 137 128 143 129" stroke-width="5"/>
    <path fill="#12100c" stroke="none" d="M136 140 C124 126 98 122 86 134 C98 136 104 141 108 147
      C116 157 128 154 136 146 C144 154 156 157 164 147 C168 141 174 136 186 134
      C174 122 148 126 136 140 Z"/>
    <path d="M120 158 C128 164 142 164 150 157"/>
    <path d="M112 168 C120 180 128 186 135 188 C142 186 150 180 158 168"/>
    <path d="M135 188 L135 212" stroke-width="5"/>
    <path d="M86 232 C90 202 98 180 112 168 M184 232 C180 202 172 180 158 168"/>
    <g transform="translate(48 126) rotate(-14)">
      <path fill="#12100c" fill-opacity=".22" stroke="none"
            d="M-15 8 C-15 26 -8 35 0 37 C8 35 15 26 15 8 Z"/>
      <path d="M-17 4 C-17 24 -9 35 0 37 C9 35 17 24 17 4 Z"/>
      <path d="M-17 4 L17 4 M0 37 L0 60 M-12 62 L12 62"/>
    </g>
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
<div class="fig">${SIR}</div>
<div class="txt">
  <h1>Kourt</h1>
  <div class="rule"></div>
  <p>Stake on claims of fact. Your principal always returns 1&times;.</p>
  <div class="foot"><span>kourt.xyz</span><span class="said">&ldquo;Gentlemen.&rdquo;</span></div>
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
