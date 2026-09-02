// The map's labels are the site's type, at the site's proportions.
//
// WHY THIS EXISTS. Reported as "the map node font etc is different than the
// site. same font, and larger nodes too, i can't read". Nothing was wrong with
// the font-family: SVG text inherits from body, so the labels really were the
// page's --sans. They were that face STRETCHED — measured over the live covid
// docket, claim titles rendered 1.27x wider than their own glyphs on average
// and 1.41x at worst. A quarter-wider sans is not the same sans, and it reads
// as some other typeface entirely, which is what the report was describing.
//
// The cause was one constant doing two jobs. est() computed textLength as
// `len * fs * charW` with charW a single 0.62, while the real advance is 0.49em
// for a title, 0.55 for the court's name, 0.63 for an id — and the surplus was
// handed to `lengthAdjust="spacingAndGlyphs"`, which spends it by SCALING THE
// OUTLINES. charW was right as the conservative fit budget it was written to
// be; it was never a rendering width.
//
// WHY A BROWSER CHECK AND NOT A SOURCE ONE. The fix measures with a canvas, so
// its whole value is in a real text engine's numbers. Under plain node —
// web/tests/*.js eval mapSvg directly — there is no document, mctx is null, and
// the estimate path runs instead. So the source harnesses cannot observe
// distortion even in principle: they would measure the fallback and pass. The
// division is deliberate and neither side subsumes the other:
//
//   web/tests/map_test.js   the label GEOMETRY — x, y, size, clipping, owner
//   this check              that the glyphs are undeformed and in the right face
//
// ABLATED, four ways, and the arm that fires is recorded because two of them
// fire somewhere other than where they were expected to:
//
//   forcing mctx=null, i.e. the old charW estimate   ratio 1.14, undeformed fails
//   lengthAdjust back to spacingAndGlyphs            ONLY the spacing arm fails
//   deleting the .mtitle/.mcourt-t serif rule        ratio 0.927, undeformed fails
//   faceOf measuring mcourt-t at 400, not 700        ratio 0.937, undeformed fails
//
// The second is why the lengthAdjust assertion has to exist separately: with a
// measured width the two modes render identically, so the ratios stay at 1.00
// and nothing else notices the unsafe mode is back. The third is the converse —
// removing the CSS face does NOT show up first as a face failure, because
// mapSvg measures in the face it believes is set, so a face changed in only one
// of the two places lands as distortion. Either way the check names the class.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1440, height: 950});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // The court comes from the directory, not from a slug written in this file —
  // a hardcoded one outlives the dataset that named it.
  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 800));
  const slug = await page.evaluate(() => {
    return [...document.querySelectorAll('a[href^="#/c/"]')]
      .map(x => x.getAttribute('href'))
      .map(h => (h.match(/^#\/c\/([a-z0-9-]+)$/) || [])[1])
      .find(Boolean) || null;
  });
  ok("the directory offers a court to open", !!slug, slug ? "slug=" + slug : "none found");
  if (!slug) { await browser.close(); process.exit(1); }

  await page.evaluate(s => { location.hash = "/c/" + s + "/map"; }, slug);
  for (let i = 0; i < 20; i++) {
    if (await page.evaluate(() => !!document.querySelector('.mapwrap svg text.mtext'))) break;
    await new Promise(r => setTimeout(r, 400));
  }

  const m = await page.evaluate(() => {
    const svg = document.querySelector('.mapwrap svg');
    if (!svg) return {err: "no svg"};
    // RESOLVED THROUGH THE ENGINE, not read as a raw token. Chrome rewrites a
    // computed font stack — it quotes entries, joins with ", " and maps
    // BlinkMacSystemFont onto system-ui — so the authored --sans string and the
    // --sans a node actually computes to are different text for the same fonts.
    // A probe styled with the token goes through the identical rewrite, which
    // makes the comparison an equality of fonts rather than of punctuation.
    const tokens = {};
    const probe = document.createElement('span');
    probe.style.position = 'absolute'; probe.style.visibility = 'hidden';
    document.body.appendChild(probe);
    for (const t of ["--serif", "--sans", "--mono"]) {
      probe.style.fontFamily = "var(" + t + ")";
      tokens[t] = getComputedStyle(probe).fontFamily.trim();
    }
    probe.remove();
    const per = {};
    for (const x of svg.querySelectorAll('text.mtext')) {
      const cls = (x.getAttribute('class') || "").replace('mtext ', '').split(/\s+/)[0];
      const imposed = parseFloat(x.getAttribute('textLength'));
      const txt = x.textContent || "";
      if (!isFinite(imposed) || !txt.length) continue;
      // Natural width: the same glyphs at the same size with no width forced on
      // them. Cloned into the same parent so it inherits identical CSS.
      const c = x.cloneNode(true);
      c.removeAttribute('textLength'); c.removeAttribute('lengthAdjust');
      x.parentNode.appendChild(c);
      const nat = c.getComputedTextLength();
      c.remove();
      if (!nat) continue;
      const ratio = imposed / nat;
      if (!per[cls]) per[cls] = {cls, n: 0, worst: 1, sum: 0, worstText: "",
                                 family: getComputedStyle(x).fontFamily.trim(),
                                 weight: getComputedStyle(x).fontWeight,
                                 lengthAdjust: x.getAttribute('lengthAdjust')};
      const r = per[cls]; r.n++; r.sum += ratio;
      if (Math.abs(ratio - 1) > Math.abs(r.worst - 1)) { r.worst = ratio; r.worstText = txt.slice(0, 30); }
    }
    const kinds = Object.values(per).map(r => ({
      cls: r.cls, n: r.n, family: r.family, weight: r.weight, lengthAdjust: r.lengthAdjust,
      mean: +(r.sum / r.n).toFixed(3), worst: +r.worst.toFixed(3), worstText: r.worstText}));
    return {tokens, kinds, total: kinds.reduce((a, k) => a + k.n, 0)};
  });

  ok("labels were found to measure", !m.err && m.total >= 8, m.err || ("measured=" + m.total));
  if (m.err) { await browser.close(); process.exit(1); }

  // ---------------------------------------------------------------- undeformed
  // 2% either way. Not zero: a canvas measures the width the text engine will
  // lay out, and SVG rounds it, so an exact 1.000 would be a test of the
  // rounding rather than of the fix.
  for (const k of m.kinds) {
    ok(`${k.cls}: glyphs undeformed (mean ${k.mean}, worst ${k.worst} over ${k.n})`,
       Math.abs(k.mean - 1) <= 0.02 && Math.abs(k.worst - 1) <= 0.02,
       k.worstText ? `worst on "${k.worstText}"` : "");
    // A ratio of 1 with spacingAndGlyphs still passes the check above today and
    // deforms the day the measurement misses, so the safe mode is pinned too.
    ok(`${k.cls}: width is spent on spacing, never on outlines`,
       k.lengthAdjust === "spacing", "lengthAdjust=" + k.lengthAdjust);
  }

  // ---------------------------------------------------------------------- face
  // Compared against the PAGE'S OWN TOKENS read at runtime, not against a copy
  // of the stack pasted in here — a check that hardcodes the font list passes
  // after somebody changes --serif and the map stops matching the site.
  // The weight is checked beside the face because mapSvg's measurement has to
  // know both — the canvas measured the court's name at 400 while the CSS drew
  // it at 700, and 6% of crowding is what that mistake looks like. Anything
  // that changes a weight in the stylesheet and not in faceOf lands here.
  const faceFor = {"mtitle": ["--serif", "400"], "mcourt-t": ["--serif", "700"],
                   "mid": ["--mono", "600"], "mhdr-t": ["--sans", "600"],
                   "mverdict": ["--sans", "600"]};
  // getComputedStyle returns a NORMALISED stack — quotes added, ", " between
  // entries — while the custom property is the authored string. Comparing them
  // raw fails on punctuation while the fonts agree, so both sides are reduced
  // to a bare list of family names first.
  const norm = s => String(s).replace(/["']/g, "").split(",")
                    .map(x => x.trim().toLowerCase()).filter(Boolean).join(",");
  ok("the font tokens survive normalising", norm(m.tokens["--serif"]).length > 8,
     norm(m.tokens["--serif"]).slice(0, 40));
  for (const k of m.kinds) {
    const want = faceFor[k.cls];
    if (!want) { console.log("note: no face expectation for " + k.cls); continue; }
    ok(`${k.cls}: drawn in the site's ${want[0]}`,
       norm(k.family) === norm(m.tokens[want[0]]), `got ${k.family.slice(0, 46)}`);
    ok(`${k.cls}: at the weight mapSvg measures it at (${want[1]})`,
       String(k.weight) === want[1], `got ${k.weight}`);
  }
  // The expectation table must not quietly stop covering the map.
  const uncovered = m.kinds.filter(k => !faceFor[k.cls]).map(k => k.cls);
  ok("every label class on the map has a face expectation", uncovered.length === 0,
     uncovered.join(","));
  // And the two faces must actually differ, or "titles are serif" proves nothing.
  ok("the site's serif and sans are different stacks",
     m.tokens["--serif"] && m.tokens["--serif"] !== m.tokens["--sans"]);

  // -------------------------------------------------------------- contrast
  /* GREY ON GREY IS A READING FAILURE, AND IT WAS ONE. Reported as "i can't read
     because the fore and back is greyish": the claim title was drawn in --ink-2,
     a slate, measured at 6.66:1 in light and 7.66:1 in dark — passing WCAG AA
     and still visibly grey, sitting inside the same box as an id drawn in --ink
     at 15.61:1. Two inks on one card, and the muted one carried the sentence.
     Measured in BOTH THEMES because they are separate palettes: a token pair
     that is fine on white can collapse on near-black, and this page ships both.
     The floor is 7:1 — WCAG AAA for body text — for everything that carries
     content, and AA's 4.5 for the verdict line, which is deliberately secondary.
     Literals, not the tokens: an expectation spelled as var(--ink) would follow
     the token wherever it went. */
  const WANT = {mtitle: 7, mid: 7, "mcourt-t": 7, "mhdr-t": 7, mverdict: 4.5};
  for (const scheme of ["light", "dark"]) {
    await page.emulateMediaFeatures([{name: 'prefers-color-scheme', value: scheme}]);
    await page.goto(PAGE + '#/c/' + slug + '/map', {waitUntil: 'networkidle2'});
    for (let i = 0; i < 20; i++) {
      if (await page.evaluate(() => !!document.querySelector('.mapwrap svg text'))) break;
      await new Promise(r => setTimeout(r, 400));
    }
    await new Promise(r => setTimeout(r, 1800));
    const seen = await page.evaluate(() => {
      const rgb = t => { const m = String(t).match(/[\d.]+/g) || []; return m.length >= 3 ? [+m[0], +m[1], +m[2]] : null; };
      const lum = c => { const f = c.map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
        return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]; };
      const ratio = (a, b) => { if (!a || !b) return null; const x = lum(a), y = lum(b);
        const [h, l] = x > y ? [x, y] : [y, x]; return +((h + 0.05) / (l + 0.05)).toFixed(2); };
      // The court is a <g>, not an <a> — the first version of this probe looked
      // only for an anchor and reported the court's contrast as null.
      const boxOf = {mtitle: '.mnode', mid: '.mnode', mverdict: '.mnode',
                     'mhdr-t': '.mfold', 'mcourt-t': '.mcourt'};
      const out = {};
      for (const t of document.querySelectorAll('.mapwrap svg text')) {
        const cls = (t.getAttribute('class') || "").replace('mtext ', '').split(/\s+/)[0];
        if (out[cls]) continue;
        const holder = t.closest('a,g.mcourt-a');
        const box = holder ? holder.querySelector(boxOf[cls] || 'rect') : null;
        if (!box) continue;
        out[cls] = ratio(rgb(getComputedStyle(t).fill), rgb(getComputedStyle(box).fill));
      }
      return out;
    });
    for (const [cls, floor] of Object.entries(WANT)) {
      const got = seen[cls];
      ok(`${scheme}: ${cls} reads against its own box (${got}:1, needs ${floor})`,
         got !== undefined && got !== null && got >= floor);
    }
    /* AND THE TITLE MATCHES THE ID, which is the invariant the floors alone
       cannot express. Reverting the title to --ink-2 fails the 7:1 floor in
       LIGHT at 6.66 and slips past it in DARK at 7.66 — so a floor high enough
       to catch both would have to sit above 7.66, and the court's own name is
       legitimately 7.31 there. No single number separates them.
       These two labels share one box and both carry content, so they should
       carry the same ink; the bug was that they did not. Comparing them catches
       the regression in either theme without inventing a threshold. */
    ok(`${scheme}: the title is the same ink as the id in the same box`,
       seen.mtitle != null && seen.mid != null && Math.abs(seen.mtitle - seen.mid) < 0.2,
       `title ${seen.mtitle} vs id ${seen.mid}`);
  }
  await page.emulateMediaFeatures([{name: 'prefers-color-scheme', value: 'light'}]);

  ok("no page errors on the map route", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
