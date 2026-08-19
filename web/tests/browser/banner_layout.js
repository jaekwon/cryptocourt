// Measures the banner's real geometry against the rail's, at three widths.
// The bug being pinned: the banner spanned every grid column, so the sticky
// opaque rail painted over its left third and the sentence began off-screen.
const puppeteer = require('puppeteer');
const PAGE = 'file://' + require('path').join(__dirname,'..','..','index.html');

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (n, c, extra) => { if (!c) { fail++; console.log("FAIL:", n, extra||""); } else console.log("ok:", n, extra||""); };

  for (const w of [1440, 1100, 720]) {
    await page.setViewport({width: w, height: 900});
    await page.goto(PAGE, {waitUntil: 'domcontentloaded'});
    // Force the banner visible with representative copy — we are measuring
    // layout, not the query path (that has its own harness).
    await page.evaluate(() => {
      const el = document.getElementById('tcbanner');
      el.innerHTML = `<div class="tcbar"><span class="g">⏱</span><div><b>Test chain — the dates here are fabricated.</b>
        This node's clock was set by hand — its dates were moved forward 84 days. The clock is sealed, so they are now fixed. Heights, balances and stakes are real.</div></div>`;
      el.hidden = false;
    });
    await new Promise(r => setTimeout(r, 120));
    const m = await page.evaluate(() => {
      const b = document.querySelector('#tcbanner .tcbar').getBoundingClientRect();
      const rail = document.querySelector('.rail').getBoundingClientRect();
      const main = document.querySelector('.main').getBoundingClientRect();
      const bold = document.querySelector('#tcbanner b').getBoundingClientRect();
      return {b:{l:b.left,r:b.right,t:b.top,b:b.bottom}, rail:{l:rail.left,r:rail.right,b:rail.bottom},
              main:{l:main.left,r:main.right,t:main.top}, bold:{l:bold.left,t:bold.top},
              vw: innerWidth, docScrollW: document.documentElement.scrollWidth};
    });
    const narrow = w <= 900; // the single-column breakpoint
    const tag = `@${w}px`;
    ok(`${tag} banner starts clear of the rail`, m.b.l >= (narrow ? 0 : m.rail.r) - 0.5,
       `banner.left=${m.b.l.toFixed(1)} rail.right=${m.rail.r.toFixed(1)}`);
    ok(`${tag} the bold opening words are visible`, m.bold.l >= (narrow ? 0 : m.rail.r) - 0.5,
       `bold.left=${m.bold.l.toFixed(1)}`);
    ok(`${tag} banner sits ABOVE the page body`, m.b.b <= m.main.t + 1,
       `banner.bottom=${m.b.b.toFixed(1)} main.top=${m.main.t.toFixed(1)}`);
    if (!narrow) ok(`${tag} left-aligned with the page content`, Math.abs(m.b.l - (m.main.l + 0)) < 60,
       `banner.left=${m.b.l.toFixed(1)} main.left=${m.main.l.toFixed(1)}`);
    ok(`${tag} fits the viewport`, m.b.r <= m.vw + 0.5, `banner.right=${m.b.r.toFixed(1)} vw=${m.vw}`);
    ok(`${tag} no horizontal page scroll`, m.docScrollW <= m.vw + 1, `scrollW=${m.docScrollW}`);
  }

  // and with the banner hidden, the page must look exactly as it always did
  await page.setViewport({width: 1440, height: 900});
  await page.goto(PAGE, {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 120));
  const hid = await page.evaluate(() => {
    const el = document.getElementById('tcbanner');
    const main = document.querySelector('.main').getBoundingClientRect();
    const rail = document.querySelector('.rail').getBoundingClientRect();
    return {hidden: el.hidden, mainTop: main.top, railTop: rail.top, railH: rail.height};
  });
  ok("ordinary chain: banner hidden", hid.hidden === true);
  ok("ordinary chain: page body still at the top", hid.mainTop < 40, `main.top=${hid.mainTop.toFixed(1)}`);
  ok("ordinary chain: rail still full height", hid.railH > 600, `rail.height=${hid.railH.toFixed(1)}`);

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
