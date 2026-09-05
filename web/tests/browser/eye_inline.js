// THE EYE SITS IN THE LINE, IT DOES NOT TAKE ONE.
//
// The reset at the top of index.html is `img,svg{display:block}`, which is right
// for every picture on the site and wrong for the one glyph that is drawn rather
// than typed. An <svg> dropped straight into a line of text becomes a block and
// takes a line of its own: the set page's heading rendered the eye above the
// name, two lines where there is one thing. Reported on a live set page.
//
// Every other surface wraps it — .setmark in a title, .id in a row, .foldbox in
// the selector — so the bug was invisible until the one unwrapped case shipped.
// That makes it a CLASS, not an incident, so this checks every eye a page draws
// rather than the heading that was reported.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');
const ROUTES = ["#/c/orem", "#/c/orem/f/0", "#/c/orem/f/1", "#/c/orem/11", "#/c/orem/map"];

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await page.setViewport({width: 1280, height: 900});

  let total = 0;
  for (const r of ROUTES) {
    await page.goto(PAGE + r, {waitUntil: 'networkidle0'});
    await new Promise(z => setTimeout(z, 800));
    const eyes = await page.evaluate(() => {
      /* AN SVG INSIDE ANOTHER SVG IS NOT THIS BUG: the map draws its own, in a
         coordinate system where `display` means nothing. Only the eyes laid out
         by CSS are in scope. */
      /* THE TEST IS WHETHER IT BREAKS THE LINE, not what `display` says. A
         correctly wrapped eye IS display:block — the reset still applies to the
         <svg>; what fixes it is the inline-flex span around it, so an eye that
         fills its own tight wrapper is right and one that pushes its neighbour
         onto another row is wrong. An earlier version compared the eye's width
         to its parent's and failed on every correct case. */
      const rowOf = e => {
        const host = e.closest("h1,h2,h3,p,li,td,button,a,.crow,.id,.t") || e.parentElement;
        const er = e.getBoundingClientRect();
        // the nearest text that shares the eye's box: does it sit beside it?
        const walk = document.createTreeWalker(host, NodeFilter.SHOW_TEXT);
        let n, best = null;
        while ((n = walk.nextNode())) {
          if (!n.nodeValue.trim()) continue;
          const rg = document.createRange(); rg.selectNodeContents(n);
          const tr = rg.getBoundingClientRect();
          if (tr.width && (best === null || tr.x < best.x)) best = tr;
        }
        return {er, tr: best};
      };
      return [...document.querySelectorAll(".eye")]
        .filter(e => !e.closest("svg.mapsvg"))
        .map(e => {
          const p = e.parentElement;
          const {er, tr} = rowOf(e);
          return {display: getComputedStyle(e).display,
                  wrap: p ? (p.className.baseVal !== undefined ? p.className.baseVal : String(p.className)) : "",
                  parentTag: p ? p.tagName : "",
                  // no text beside it (a bare icon) is fine; text on another row is not
                  breaksLine: tr ? Math.abs(er.y - tr.y) > er.height * 0.75 : false};
        });
    });
    total += eyes.length;
    const blocky = eyes.filter(e => e.breaksLine);
    ok(`${r}: every eye stays in its line`, blocky.length === 0,
       JSON.stringify(blocky.slice(0, 2)));
  }
  ok("the pages actually drew some eyes", total > 0, String(total));

  /* THE HEADING THAT WAS REPORTED, measured as the reader saw it: the eye above
     the name made an 80px h1 out of a 40px one. Height, not just "same line",
     because a heading that wraps for any other reason is the same defect. */
  await page.goto(PAGE + "#/c/orem/f/0", {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 800));
  const head = await page.evaluate(() => {
    const h = document.querySelector("h1.page-h"), eye = h.querySelector(".eye");
    const er = eye.getBoundingClientRect();
    const rg = document.createRange();
    const tn = [...h.childNodes].find(n => n.nodeType === 3 && n.nodeValue.trim());
    rg.selectNodeContents(tn);
    const tr = rg.getBoundingClientRect();
    return {h: Math.round(h.getBoundingClientRect().height),
            wrapped: !!eye.closest(".setmark"),
            gap: Math.round(Math.abs(er.y - tr.y)), eyeH: Math.round(er.height)};
  });
  ok("the set page's eye and its name share a line",
     head.gap < head.eyeH * 0.6, JSON.stringify(head));
  ok("...so the heading is one line tall", head.h < 60, JSON.stringify(head));
  ok("...and the eye is wrapped, like every other one", head.wrapped, JSON.stringify(head));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
