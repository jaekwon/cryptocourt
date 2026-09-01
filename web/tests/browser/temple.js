// The court's name is a temple: one stone lifted by two.
//
// WHY THIS EXISTS. Asked for as "i want 'COVID-19 Origins Court' to look like a
// temple on the screen. top bar. marble. like a stone lifted by two stones
// beneath it", then "sharp edges of gold. a credit card couldn't fit in."
//
// Every clause there is a measurable fact and none of them is visible in the
// source: whether two piers exist under the beam, whether the joint between
// them is a shared line or a gap, whether the corners are square, whether the
// edge is the palette's gold, and whether the name still reads on marble.
//
// THE CREDIT CARD IS THE POINT. The piers are pulled up by exactly the width of
// the line they meet — margin-top:-1px against border-top:0 — so the beam's
// bottom edge and the pier's top edge are the SAME pixel row. That is one gold
// seam, not two lines with daylight between them. It is also the assertion most
// likely to rot: any later change to either border width silently opens the
// joint, and at this scale a 1px gap reads as a mistake rather than as masonry.
//
// SCOPED, AND THAT IS CHECKED. The temple is the COURT's name, not every h1 on
// the site — a claim page's title must stay a plain heading. A rule written
// against .page-h instead of .leadface .page-h would put piers under every page
// on the site, which is the kind of thing that looks deliberate for a week.
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
  await page.setViewport({width: 1280, height: 900});

  const slug = await (async () => {
    await page.goto(PAGE + '#/', {waitUntil: 'networkidle2'});
    await new Promise(r => setTimeout(r, 900));
    return page.evaluate(() => [...document.querySelectorAll('a[href^="#/c/"]')]
      .map(x => x.getAttribute('href'))
      .map(h => (h.match(/^#\/c\/([a-z0-9-]+)$/) || [])[1]).find(Boolean) || null);
  })();
  ok("the directory offers a court to open", !!slug, slug || "none");
  if (!slug) { await browser.close(); process.exit(1); }

  for (const scheme of ["light", "dark"]) {
    await page.emulateMediaFeatures([{name: 'prefers-color-scheme', value: scheme}]);
    await page.goto(PAGE + '#/c/' + slug, {waitUntil: 'networkidle2'});
    await new Promise(r => setTimeout(r, 1800));

    const t = await page.evaluate(() => {
      const beam = document.querySelector('.leadface .page-h');
      if (!beam) return {err: "no beam"};
      const cs = getComputedStyle(beam);
      const pier = (which) => {
        const p = getComputedStyle(beam, which);
        return {w: p.width, h: p.height, top: p.top, mt: p.marginTop,
                bt: p.borderTopWidth, bl: p.borderLeftWidth,
                colour: p.borderLeftColor, radius: p.borderRadius,
                bg: p.backgroundColor, img: p.backgroundImage, content: p.content};
      };
      const gilt = getComputedStyle(document.documentElement).getPropertyValue('--gilt').trim();
      // Resolve the token through the engine so the comparison is colour to
      // colour, not "#9a6f12" against "rgb(154, 111, 18)".
      const probe = document.createElement('span');
      probe.style.color = "var(--gilt)"; document.body.appendChild(probe);
      const giltRGB = getComputedStyle(probe).color; probe.remove();
      return {
        beam: {radius: cs.borderRadius, bw: cs.borderTopWidth, colour: cs.borderTopColor,
               bg: cs.backgroundColor, img: cs.backgroundImage, align: cs.textAlign,
               colour_text: cs.color, rect: beam.getBoundingClientRect().toJSON()},
        before: pier('::before'), after: pier('::after'),
        gilt, giltRGB,
      };
    });
    ok(`${scheme}: the beam is there`, !t.err, t.err || "");
    if (t.err) continue;

    // ------------------------------------------------------------- two stones
    for (const [name, p] of [["left", t.before], ["right", t.after]]) {
      ok(`${scheme}: a ${name} pier stands under the beam`,
         p.content !== "none" && parseFloat(p.h) > 10, `h=${p.h} content=${p.content}`);
      // THE CREDIT CARD. margin-top:-1px against a zeroed top border is the
      // whole joint: the pier is pulled up onto the beam's bottom edge so the
      // two share one line. Either half changing opens a gap.
      ok(`${scheme}: the ${name} joint is one shared line, not a gap`,
         p.mt === "-1px" && p.bt === "0px", `margin-top=${p.mt} border-top=${p.bt}`);
      ok(`${scheme}: the ${name} pier is square-cornered`, p.radius === "0px", p.radius);
      ok(`${scheme}: the ${name} pier's edge is the palette's gold`,
         p.colour === t.giltRGB, `${p.colour} vs ${t.giltRGB}`);
      ok(`${scheme}: the ${name} pier is cut from the same marble`,
         /url\(/.test(p.img) && p.bg !== "rgba(0, 0, 0, 0)", p.bg);
    }

    // ------------------------------------------------------------- the lintel
    ok(`${scheme}: the beam is square-cornered — no radius anywhere`,
       t.beam.radius === "0px", t.beam.radius);
    ok(`${scheme}: the beam's edge is gold, one line thick`,
       t.beam.colour === t.giltRGB && t.beam.bw === "1px",
       `${t.beam.colour} @ ${t.beam.bw}`);
    ok(`${scheme}: the beam is marble over an opaque fill`,
       /url\(/.test(t.beam.img) && t.beam.bg !== "rgba(0, 0, 0, 0)", t.beam.bg);
    // A temple is symmetrical; a left-aligned name on a spanning beam is a sign.
    ok(`${scheme}: the name is centred on its stone`, t.beam.align === "center", t.beam.align);

    // ------------------------------------------------------- still readable
    // Marble is texture UNDER type. If carrying it cost the name its contrast
    // the whole thing would be a decoration that ate its own content.
    const ratio = await page.evaluate(() => {
      const rgb = s => { const m = String(s).match(/[\d.]+/g) || []; return [+m[0], +m[1], +m[2]]; };
      const lum = c => { const f = c.map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
        return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]; };
      const b = document.querySelector('.leadface .page-h'), cs = getComputedStyle(b);
      const x = lum(rgb(cs.color)), y = lum(rgb(cs.backgroundColor));
      const [h, l] = x > y ? [x, y] : [y, x];
      return +((h + 0.05) / (l + 0.05)).toFixed(2);
    });
    ok(`${scheme}: the court's name still clears AAA on marble (${ratio}:1)`, ratio >= 7);
  }

  // ------------------------------------------------------------------ scoped
  // A claim page's heading must be a heading. This is what stops the rule being
  // widened to .page-h and quietly colonnading the whole site.
  await page.emulateMediaFeatures([{name: 'prefers-color-scheme', value: 'light'}]);
  await page.goto(PAGE + '#/c/' + slug + '/1', {waitUntil: 'networkidle2'});
  await new Promise(r => setTimeout(r, 1600));
  const claim = await page.evaluate(() => {
    const h = document.querySelector('.page-h');
    if (!h) return null;
    return {inTemple: !!h.closest('.leadface'),
            before: getComputedStyle(h, '::before').content,
            radius: getComputedStyle(h).borderRadius,
            border: getComputedStyle(h).borderTopWidth};
  });
  ok("a claim page still has a heading to check", !!claim);
  if (claim) {
    ok("a claim's title is not inside the temple", claim.inTemple === false);
    ok("...and carries no piers of its own",
       claim.before === "none", claim.before);
    ok("...and no stone edge", claim.border === "0px" || claim.border === "0px none",
       claim.border);
  }

  ok("no page errors in either theme", errs.length === 0, errs.slice(0, 2).join(" | "));
  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
