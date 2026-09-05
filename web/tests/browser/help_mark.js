// THE `?` HAS TO BE VISIBLE, WHICH IS A MEASUREMENT.
//
// Reported: "the (?) are hard to see". They were — the glyph sat at --muted and
// the ring at --line-2, which in the dark theme is #2b3843 on a near-black page.
// A source pin saying `color:var(--ink)` would not have caught that: the old
// rule also named a token, and the token was the problem.
//
// So this reads the rendered pixels. Both marks, both themes, glyph and ring
// measured separately against the surface behind them — the ring is what failed,
// and a check that only looked at the glyph would have passed the bug.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');

// WCAG relative luminance and contrast ratio.
const lum = ([r, g, b]) => {
  const f = c => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
};
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
/* TWO SHAPES AND AN ALPHA. getComputedStyle hands back rgb()/rgba() in 0-255 but
   a color-mix() resolves to `color(srgb 0.9 0.93 0.95 / 0.45)` — 0-to-1 floats
   and a fourth number. Reading those as 0-255 makes a near-white ring measure as
   black, which is how this check first failed on the fix it was written for. */
const parse = s => {
  const n = (s.match(/-?\d*\.?\d+(e-?\d+)?/gi) || []).map(Number);
  const srgb = /^color\(/.test(s);
  const [r, g, b] = n.slice(0, 3).map(v => srgb ? v * 255 : v);
  return {rgb: [r, g, b], a: n.length > 3 ? n[3] : 1};
};
// what the eye sees: a translucent mark is its colour laid over the surface
const over = (fg, bg) => fg.rgb.map((c, i) => fg.a * c + (1 - fg.a) * bg.rgb[i]);
const contrast = (fgs, bgs) => { const bg = parse(bgs); return ratio(over(parse(fgs), bg), bg.rgb); };

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  for (const scheme of ['dark', 'light']) {
    const page = await browser.newPage();
    await page.emulateMediaFeatures([{name: 'prefers-color-scheme', value: scheme}]);
    await page.evaluateOnNewDocument(() => {
      localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
      localStorage.setItem("cc.intro", "1");
    });
    await page.setViewport({width: 1280, height: 1100});
    await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
    await new Promise(r => setTimeout(r, 900));

    const marks = await page.evaluate(() => {
      /* THE SURFACE BEHIND IT, not document.body: these sit on a heading and in
         a docket row, and a transparent parent is not what the eye sees. */
      const behind = el => {
        for (let n = el.parentElement; n; n = n.parentElement) {
          const c = getComputedStyle(n).backgroundColor;
          if (c && !/rgba?\([^)]*,\s*0\s*\)/.test(c) && c !== "transparent") return c;
        }
        return getComputedStyle(document.body).backgroundColor;
      };
      const read = (sel, ringSel) => {
        const e = document.querySelector(sel); if (!e) return null;
        const ring = ringSel ? e.querySelector(ringSel) : e;
        return {glyph: getComputedStyle(e).color,
                ring: getComputedStyle(ring).borderTopColor,
                bg: behind(e)};
      };
      /* THE FOREGROUND COLOUR, RESOLVED. Asked for as "white like the map",
         which in a stylesheet with a light theme means --ink — the token for
         "the text colour" — not the literal white. Resolved through a probe
         rather than compared as a token name, so renaming the variable does not
         break this and re-pointing the mark at a dimmer one does. */
      const probe = document.createElement("span");
      probe.style.color = "var(--ink)"; document.body.appendChild(probe);
      const ink = getComputedStyle(probe).color; probe.remove();
      return {ink, sq: read(".sq", ".sqd"), vqm: read(".vqm", null)};
    });

    for (const [name, m] of Object.entries(marks)) {
      if (name === "ink") continue;
      if (!m) { ok(`${scheme}: .${name} is on the court page`, false); continue; }
      /* CONTRAST ALONE CANNOT SAY THIS. --muted measures 6.16:1 in the dark
         theme and passes every threshold here, and --muted is exactly what was
         reported as hard to see. The ask was that the mark be drawn in the
         text's own colour, so that is the thing asserted. */
      ok(`${scheme}: the ${name} mark is drawn in the text colour`, m.glyph === marks.ink,
         `${m.glyph} vs --ink ${marks.ink}`);
      const g = contrast(m.glyph, m.bg);
      const r = contrast(m.ring, m.bg);
      /* 4.5:1 is WCAG's threshold for text this size, 3:1 for the shape of a
         control. The ring is what was reported: it measured 1.28:1 before. */
      ok(`${scheme}: the ${name} glyph reads against its surface`, g >= 4.5,
         `${g.toFixed(2)}:1  ${m.glyph} on ${m.bg}`);
      ok(`${scheme}: ...and its ring is a visible circle`, r >= 3,
         `${r.toFixed(2)}:1  ${m.ring} on ${m.bg}`);
    }
    await page.close();
  }
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
