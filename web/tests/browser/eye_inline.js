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

  /* A SET PAGE OFFERS A WAY TO ACT. It listed a set's claims and stopped, so a
     reader who had just read three claims on one subject and wanted to file a
     fourth had to find their way back to the court first. Asked for.
     AND IT DOES NOT PROMISE THE SET. AddToFolder is moderator-only and no
     OpenClaim variant takes a set, so a claim opened here lands in the court's
     docket and a moderator files it. A button reading "file a claim in this set"
     would name an outcome the chain will not deliver — and the reader would
     learn that after paying for the claim. */
  for (const r of ["#/c/orem/f/0", "#/c/orem/f/1"]) {
    await page.goto(PAGE + r, {waitUntil: 'networkidle0'});
    await new Promise(z => setTimeout(z, 800));
    const act = await page.evaluate(() => {
      const a = document.querySelector(".main .actions");
      if (!a) return {none: true};
      const b = a.querySelector(".btn");
      const sec = a.closest("section");
      const dk = sec ? sec.querySelector(".docket, .empty") : null;
      return {label: b ? b.textContent.trim() : null,
              fn: b ? (b.dataset.fn || b.getAttribute("data-fn")) : null,
              // it belongs under the list, not above it
              belowList: dk ? dk.getBoundingClientRect().bottom <= a.getBoundingClientRect().top + 2 : null};
    });
    ok(`${r}: the set page offers a way to file a claim`, !act.none && /Open a claim/.test(act.label || ""),
       JSON.stringify(act));
    ok(`${r}: ...and says the claim opens in the court, not in the set`,
       /opens in \w+; a moderator files it here/.test(act.label || ""), JSON.stringify(act.label));
    ok(`${r}: ...and it does not claim to file into the set`,
       !/(file|filed) (a claim )?(in|into) this set/i.test(act.label || ""), JSON.stringify(act.label));
    ok(`${r}: ...sitting under the list it belongs to`, act.belowList === true, JSON.stringify(act));
  }

  /* THE FIGURE AND ITS CAPTION STACK. `.px` is a flex column — figure over
     caption — and the rule was narrowed to `.docket .crow.px`, which matches
     NOTHING: the cell is INSIDE the row, not the row itself. So the two ran
     together inline and wrapped: "53.1%staked" on one line with "YES" beneath.
     Reported from the live docket, and invisible to any source-level check,
     since the selector it broke is still spelled plausibly. */
  /* ON ledger, NOT orem. The rule that matters is "the figure follows the
     verdict", and orem's visible docket has no settled-NO row to break — three
     mutants that severed the plumbing survived against it, all of them silently
     correct on a court where every verdict is YES. ledger has one. */
  await page.goto(PAGE + "#/c/ledger", {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1500));
  const px = await page.evaluate(() => {
    const cells = [...document.querySelectorAll(".docket .crow.claimrow .px")]
      .filter(c => c.querySelector("b") && c.querySelector("small"));
    if (!cells.length) return {none: true};
    const c = cells[0], cs = getComputedStyle(c);
    const b = c.querySelector("b").getBoundingClientRect();
    const sm = c.querySelector("small").getBoundingClientRect();
    /* READ FROM THE ROW'S OWN OVAL, not from the attribute the cell carries:
       data-side is half the mechanism under test, so comparing the caption to it
       passes when both are dropped together. The oval is built by a different
       function from a different read. */
    const rowSide = x => {
      const r = x.closest(".crow");
      const o = r && r.querySelector(".sidetag");
      const t = o ? o.textContent.trim() : "";
      return t === "YES" || t === "NO" ? t : "";
    };
    const decided = cells.filter(x => rowSide(x));
    return {n: cells.length, decided: decided.length,
            no: decided.filter(x => rowSide(x) === "NO").length,
            display: cs.display, dir: cs.flexDirection,
            // the caption sits BELOW the figure, not beside it
            stacked: sm.top >= b.bottom - 1,
            mismatched: decided.filter(x => {
              const cap = (x.querySelector("small") || {}).textContent || "";
              return !cap.includes("staked " + rowSide(x));
            }).map(x => rowSide(x) + " oval / " + (x.querySelector("small") || {}).textContent)};
  });
  ok("the docket's figure and caption stack", !px.none && px.display === "flex" && px.dir === "column",
     JSON.stringify(px));
  ok("...with the caption under the figure, not run against it", px.stacked === true, JSON.stringify(px));
  ok("...the court has a decided NO row to test against", px.no > 0, JSON.stringify(px));
  ok("...and every figure names its own row's verdict", px.mismatched.length === 0, JSON.stringify(px));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
