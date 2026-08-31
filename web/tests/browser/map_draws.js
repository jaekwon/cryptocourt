// The map actually DRAWS — nodes on screen, not an empty frame.
//
// WHY THIS EXISTS. "The map is shown" was verified three ways that all passed
// while proving nothing about pixels: the realm answers FolderTree, the overlay's
// parser accepts that string, and check-live-reads says every read returns a
// parseable shape. None of them renders anything. The map is built client-side
// from folders and claims, so every one of those can be green while the SVG comes
// out empty — and an empty map looks exactly like a court with nothing in it,
// which is the worst shape of failure because nothing suggests where to look.
//
// DEMO MODE, deliberately. The dataset ships in the file, so this runs anywhere
// with no node and no network — and the demo court is the one a first-time
// visitor lands on.
//
// WHAT THIS DOES NOT COVER, stated because the first version of this comment
// claimed otherwise. The live FolderTree path is NOT exercised here: in demo mode
// the folders come from the shipped dataset and chainFolders is never called.
// Measured — breaking the parser to demand four colon-separated fields left this
// check ALL PASS, because it never runs that code. So the two guards are
// complementary and neither subsumes the other:
//
//   check-web-constants   the realm's row width vs the parser's, by source
//   this check            that a map with data in it reaches the screen
//
// A live-chain variant would be a third, with a different failure mode again —
// the chain being empty is not a bug in the map.
//
// Ablated on the paths demo mode DOES take: renaming .mapwrap fails the first
// three assertions, and returning an empty <svg> from mapSvg fails the node and
// label counts. Those are the two ways the frame can be there and the map not.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 200)));
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await page.setViewport({width: 1400, height: 1100});

  // Find a court from the directory rather than hardcoding one: a slug written
  // into this file is the kind of thing that outlives the dataset it named.
  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 800));
  const slug = await page.evaluate(() => {
    const a = [...document.querySelectorAll('a[href^="#/c/"]')]
      .map(x => x.getAttribute('href'))
      .map(h => (h.match(/^#\/c\/([a-z0-9-]+)$/) || [])[1])
      .find(Boolean);
    return a || null;
  });
  ok("the directory offers a court to open", !!slug, slug ? "slug=" + slug : "none found");
  if (!slug) { await browser.close(); process.exit(1); }

  await page.evaluate(s => { location.hash = "/c/" + s + "/map"; }, slug);
  await new Promise(r => setTimeout(r, 1400));

  const m = await page.evaluate(() => {
    // .mapwrap svg AND NOTHING ELSE. The first version ended its selector list
    // with a bare `svg`, which matched an inline ICON — a 30x32 box with no text
    // in it — so the check measured a glyph and reported the map as undersized
    // and unlabelled while the map itself was fine. The overlay's own CSS says
    // where the map lives: `.mapwrap svg{width:100%;height:100%}`.
    const svg = document.querySelector('.mapwrap svg');
    if (!svg) return {svg: false};
    const r = svg.getBoundingClientRect();
    // Nodes are what a reader sees. Counted by the shapes the map emits rather
    // than by a class name, so a rename does not read as an empty map.
    const shapes = svg.querySelectorAll('circle, rect, path, g[data-claim], g[data-folder]');
    const texts = svg.querySelectorAll('text');
    return {svg: true, w: Math.round(r.width), h: Math.round(r.height),
            shapes: shapes.length, texts: texts.length,
            html: (document.getElementById('main') || {}).innerHTML ? "" : "no #main"};
  });

  ok("the map route renders an svg", m.svg === true);
  ok("...with real size on screen", m.svg && m.w > 200 && m.h > 150,
     m.svg ? `${m.w}x${m.h}` : "");
  // THE ASSERTION THAT MATTERS. An empty frame satisfies everything above.
  ok("...and it is not empty — it has nodes in it", (m.shapes || 0) >= 3,
     `shapes=${m.shapes} texts=${m.texts}`);
  ok("...and the nodes are labelled", (m.texts || 0) >= 1, `texts=${m.texts}`);

  // A page error is a failure even when the frame looks right: the map may have
  // drawn a first pass and thrown on the data.
  ok("no page errors on the map route", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
