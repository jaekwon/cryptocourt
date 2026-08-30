// Every label-and-value row the overlay draws, measured WHERE IT LANDS.
//
// WHY THIS EXISTS. A `.line` is the overlay's label-and-value row, and every
// rule for one was written as `.ticket .line`. That is invisible in the source:
// the markup a function emits is identical whether or not a ticket happens to be
// somewhere above it, so the same helper renders as two clean grid tracks on the
// ballot and as two bare inline spans on the quality panel, where the page read
//
//     what voting commitsCasting commits the weight you vote with, until...
//
// — the label and its prose printed as one word, with no emphasis and no column.
// Three source-reading tests pinned the exact text of those CSS rules and all
// three passed, because they proved the rule's TEXT and never that anything was
// inside its scope. Only a computed style can tell you which of the two a row
// actually got.
//
// So this crawls the demo the way route_crawl does and asks one question of
// every row it finds: did you come out as a grid? A row that did not is either
// in a container nobody styled or in one somebody renamed.
//
// It is deliberately not a list of routes. The bug was in a panel that renders
// only for a claim in a particular phase, and a hand-written route list is
// exactly the kind of thing that omits it.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');
const MAX_PAGES = 60;

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 160)));
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await page.setViewport({width: 1280, height: 1000});
  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 700));

  const seen = new Set(['#/']);
  const queue = ['#/'];
  const bad = [];
  let visited = 0, rows = 0;

  while (queue.length && visited < MAX_PAGES) {
    const route = queue.shift();
    visited++;
    await page.evaluate(r => { location.hash = r.slice(1); }, route);
    await new Promise(r => setTimeout(r, 260));

    const found = await page.evaluate(() => {
      const out = [];
      for (const el of document.querySelectorAll('.line')) {
        const cs = getComputedStyle(el);
        if (cs.display === 'grid') { out.push({ok: true}); continue; }
        out.push({ok: false, display: cs.display,
                  text: el.innerText.replace(/\s+/g, ' ').slice(0, 60)});
      }
      return out;
    });
    rows += found.length;
    for (const f of found) if (!f.ok) bad.push({route, ...f});

    const links = await page.evaluate(() =>
      [...document.querySelectorAll('.main a[href^="#/"], .rail a[href^="#/"]')]
        .map(a => a.getAttribute('href')));
    for (const h of links) {
      const r = String(h).split('?')[0];
      if (!r.startsWith('#/') || r.startsWith('#/embed/') || seen.has(r)) continue;
      seen.add(r); queue.push(r);
    }
  }

  console.log(`\ncrawled ${visited} route(s); measured ${rows} row(s)`);
  ok("every label-and-value row landed in a container that styles it",
     bad.length === 0,
     bad.slice(0, 4).map(b => `${b.route} [${b.display}] "${b.text}"`).join(" | "));

  // THE TRIPWIRE. A crawl that found four rows proves nothing, and this harness
  // would go green on a page where every row had stopped rendering at all —
  // which is the failure it would most want to report. Pinned below the count
  // observed when it was written (104 across 60 routes), loose enough that
  // adding or removing a panel does not fail the build for the wrong reason.
  ok("the crawl actually reached the pages with rows on them", rows >= 60, `saw ${rows}`);
  ok("no page threw while being measured", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
