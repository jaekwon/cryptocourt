// The page is stone, and the stone is actually visible.
//
// WHY THIS EXISTS. Asked for as "can you make the theme more like... marble/
// stone? top bar, subtly, background fill kinda thing." Subtle is the brief, and
// subtle is exactly the thing that ships broken without anyone noticing: the
// first pass rendered perfectly — six background layers, nothing dropped, the
// data URI valid — and was INVISIBLE. Sampled over a bare patch it moved the
// light theme from a flat fill to a standard deviation of 0.8 in 255, about a
// third of one per cent. It looked identical to no change at all.
//
// So there are two failure modes and they need different assertions:
//
//   the declaration is DROPPED   one bad layer in a comma-separated
//                                background-image list kills the whole property,
//                                silently — caught by the layer count
//   the declaration is FAINT     it renders and nobody can see it — caught by
//                                measuring the pixels
//
// Only the second one was the real bug, and only pixels can see it.
//
// WHY A BARE PATCH HAS TO BE PROVEN BARE. The first probe sampled a fixed corner
// of the rail and reported sd=26 on what was then a perfectly flat fill — it had
// caught the word "Directory". A patch with a glyph in it measures the glyph.
// Every point of the patch below is checked with elementFromPoint first.
//
// BOTH THEMES, because the same greyscale turbulence darkens a light ground and
// lightens a dark one, and the two need different strengths to read the same.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');

// Measured floors, set below what ships and above the first pass that nobody
// could see (light 0.8, dark 1.96). Literals, so the expectation cannot drift
// along with the CSS the way a value read out of the stylesheet would.
const FLOOR = {light: 1.2, dark: 2.4};

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

  for (const scheme of ["light", "dark"]) {
    await page.emulateMediaFeatures([{name: 'prefers-color-scheme', value: scheme}]);
    await page.setViewport({width: 1280, height: 900});
    await page.goto(PAGE + '#/', {waitUntil: 'networkidle2'});
    await new Promise(r => setTimeout(r, 2000));

    const css = await page.evaluate(() => {
      // THE RAIL, NOT BODY. A slab on body shows through every see-through
      // panel and docket row, which is why the last body texture was removed;
      // the stone lives on the rail and in .main's lintel instead.
      const cs = getComputedStyle(document.querySelector('.rail'));
      return {img: cs.backgroundImage, lintel: getComputedStyle(document.querySelector('.main')||document.body).backgroundImage,
              layers: (cs.backgroundImage.match(/url\(|linear-gradient|radial-gradient/g) || []).length,
              attach: cs.backgroundAttachment};
    });
    const bodyImage = await page.evaluate(() =>
      getComputedStyle(document.body).backgroundImage);
    ok(`${scheme}: the slab's layers all survived parsing`,
       css.img !== "none" && css.layers >= 3, `layers=${css.layers}`);
    ok(`${scheme}: the lintel washes the top of the page`,
       /linear-gradient/.test(css.lintel || ""), (css.lintel || "none").slice(0, 48));
    // BODY STAYS FLAT, on purpose and by an earlier decision of the owner's: a
    // texture there runs through every see-through panel and docket row. This is
    // the assertion that stops a future edit "simplifying" the rail's slab onto
    // body and quietly re-creating that.
    ok(`${scheme}: body itself paints no texture`,
       bodyImage === "none", bodyImage);
    // The texture is inline, because this page is one self-contained file and is
    // not allowed to fetch an image. A url() that is not a data: URI means some
    // future edit reached for a real file, which would 404 on the deployed site.
    // Written as "does any url() point OUTWARD", not "does every url() say
    // data:". The first version asked the second question and failed on the
    // texture itself: the SVG references its own filters as url(%23m), that text
    // lives inside the data URI, and a naive scan cannot tell an inner
    // reference from an outer fetch. Only a scheme or a path is a fetch.
    ok(`${scheme}: the texture is inline, not a fetch`,
       !/url\((["']?)(?:https?:|\/\/|\.{0,2}\/)/.test(css.img));
    ok(`${scheme}: it sits with the window, not the scroll`,
       /fixed/.test(css.attach), css.attach);

    const patch = await page.evaluate(() => {
      const bare = (x, y) => { const el = document.elementFromPoint(x, y);
        return el && (el === document.body || el.classList.contains('rail')); };
      for (let y = 420; y < 820; y += 20) for (let x = 20; x < 240; x += 20) {
        let clean = true;
        for (let dy = 0; dy < 80 && clean; dy += 10) for (let dx = 0; dx < 80 && clean; dx += 10)
          if (!bare(x + dx, y + dy)) clean = false;
        if (clean) return {x, y};
      }
      return null;
    });
    ok(`${scheme}: found a patch of bare page to measure`, !!patch);
    if (!patch) continue;

    const shot = await page.screenshot({clip: {x: patch.x, y: patch.y, width: 80, height: 80}});
    const st = await page.evaluate(async (b64) => {
      const img = new Image(); img.src = "data:image/png;base64," + b64; await img.decode();
      const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
      const g = c.getContext('2d'); g.drawImage(img, 0, 0);
      const d = g.getImageData(0, 0, c.width, c.height).data;
      let n = 0, s = 0, s2 = 0, min = 255, max = 0;
      for (let i = 0; i < d.length; i += 4) {
        const v = (d[i] + d[i + 1] + d[i + 2]) / 3;
        n++; s += v; s2 += v * v; if (v < min) min = v; if (v > max) max = v;
      }
      const m = s / n;
      return {mean: +m.toFixed(2), sd: +Math.sqrt(Math.max(0, s2 / n - m * m)).toFixed(3),
              spread: +(max - min).toFixed(1)};
    }, shot.toString('base64'));

    // THE ASSERTION THE WHOLE FILE IS FOR. A flat fill has a standard deviation
    // of zero; stone does not.
    ok(`${scheme}: the stone is visible, not just present (sd ${st.sd}, needs ${FLOOR[scheme]})`,
       st.sd >= FLOOR[scheme], `mean ${st.mean}, spread ${st.spread}`);
    // And not so loud it becomes a pattern the eye reads instead of the text.
    ok(`${scheme}: ...and stays a texture, not a print (sd ${st.sd} under 8)`, st.sd < 8);

    // THE TEXTURE MUST NOT COST WHAT THE LAST CHANGE BOUGHT. Body copy sits
    // directly on this background in places, and a mottle that moves the ground
    // far enough would eat the contrast the map work just fixed.
    const ratio = await page.evaluate(() => {
      const rgb = t => { const m = String(t).match(/[\d.]+/g) || []; return [+m[0], +m[1], +m[2]]; };
      const lum = c => { const f = c.map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
        return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]; };
      const cs = getComputedStyle(document.body);
      const a = lum(rgb(cs.color)), b = lum(rgb(cs.backgroundColor));
      const [h, l] = a > b ? [a, b] : [b, a];
      return +((h + 0.05) / (l + 0.05)).toFixed(2);
    });
    ok(`${scheme}: body copy still clears AAA on the slab (${ratio}:1)`, ratio >= 7);
  }

  ok("no page errors in either theme", errs.length === 0, errs.slice(0, 2).join(" | "));
  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
