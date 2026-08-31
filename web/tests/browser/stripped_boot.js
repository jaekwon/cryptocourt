// The page that actually ships, in a real browser.
//
// WHY THIS EXISTS. deploy.sh strips 41% of the overlay's bytes out of the copy it
// uploads — every comment, from a file whose comments are the reason it is
// readable. strip_test proves the scanner handles the cases a regular expression
// gets wrong, and the stripper verifies its own output. Neither of those runs the
// result. A stripper that removed one character too many produces a file that
// still parses, still has every string, and throws on the first route a reader
// opens — and nothing before this would notice.
//
// So: strip, serve, and walk the routes, exactly as run.js does for the tree's
// own copy. If the shipped artifact cannot draw a claim page, this is where it
// is found, before the upload rather than after.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const puppeteer = require("puppeteer");
const { stripHtml, verify } = require("../../../scripts/strip-comments.js");

const WEB = path.join(__dirname, "..", "..");
let fail = 0, checks = 0;
// Prints on success too: run.js counts "^ok:" lines to report how much this
// check actually measured, and a silent pass reads as a vacuous one — which is
// the impression this suite exists to make impossible.
const ok = (n, c, d) => { checks++;
  if(c) console.log("ok:", n);
  else { fail++; console.log("FAIL:", n, d===undefined?"":d); } };

(async () => {
  const src = fs.readFileSync(path.join(WEB, "index.html"), "utf8");
  const { out } = stripHtml(src);
  verify(src, out);

  // served from a temp dir beside copies of the two local scripts the page loads
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "kourt-stripped-"));
  fs.writeFileSync(path.join(dir, "index.html"), out);
  for (const f of ["chat.js", "media.js"])
    if (fs.existsSync(path.join(WEB, f))) fs.copyFileSync(path.join(WEB, f), path.join(dir, f));

  const server = http.createServer((req, res) => {
    const name = (req.url.split("?")[0].split("#")[0] || "/").replace(/^\/+/, "") || "index.html";
    const p = path.join(dir, path.basename(name));
    if (!fs.existsSync(p)) { res.writeHead(404); return res.end("no"); }
    res.writeHead(200, {"content-type": name.endsWith(".js") ? "text/javascript" : "text/html"});
    res.end(fs.readFileSync(p));
  });
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/index.html`;

  const browser = await puppeteer.launch({ headless: "new" });
  const page = await browser.newPage();
  const errs = [];
  page.on("pageerror", e => errs.push(e.message));
  page.on("console", m => { if (m.type() === "error") errs.push("console: " + m.text().slice(0, 120)); });

  // Demo mode needs no chain, which is the point: this is about the FILE, not
  // about a node being up.
  const ROUTES = ["#/", "#/c/orem", "#/c/orem/1", "#/c/orem/map", "#/c/orem/curate",
                  "#/about", "#/me", "#/needs", "#/raw/orem"];
  for (const r of ROUTES) {
    await page.goto(base + r, { waitUntil: "networkidle0", timeout: 30000 });
    await new Promise(x => setTimeout(x, 500));
    const drew = await page.evaluate(() => {
      const m = document.getElementById("main");
      return m ? m.innerText.replace(/\s+/g, " ").trim().length : 0;
    });
    ok(`${r} draws something`, drew > 40, `only ${drew} characters`);
  }
  // and the mark is still there — the one thing a byte-level slip would eat
  await page.goto(base + "#/", { waitUntil: "networkidle0", timeout: 30000 });
  // Twelve ink rectangles are the DRAWING; the gilt highlight is a <g> of ten
  // more inside the same svg, which is why a bare ".seat rect" counts 22.
  const mark = await page.evaluate(() => {
    const svg = document.querySelector(".brand .seat svg");
    if (!svg) return {ink: 0, gilt: 0};
    return {ink: svg.querySelectorAll(":scope > rect").length,
            gilt: svg.querySelectorAll(':scope > g[fill*="gilt"] > rect').length};
  });
  ok("the seat is still drawn, twelve ink rectangles", mark.ink === 12, `saw ${mark.ink}`);
  ok("and its gilt highlight survived too", mark.gilt === 10, `saw ${mark.gilt}`);
  ok("no page errors on any route", errs.length === 0, errs.slice(0, 3).join(" | "));

  await browser.close();
  server.close();
  fs.rmSync(dir, { recursive: true, force: true });

  console.log(fail ? `\n${fail} FAILURES` : `\nALL PASS (${checks} measurements)`);
  process.exit(fail ? 1 : 0);
})();
