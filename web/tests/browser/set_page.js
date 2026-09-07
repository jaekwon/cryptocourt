// A set's own page: the mark beside its name, and the way into its subsets.
//
// WHY THIS NEEDS A BROWSER. Both things measured here were reported by a reader
// while every source harness stayed green, and for the same reason in each case:
// what is wrong is not in the markup.
//
//   1. THE MARK'S HEIGHT. 𓂀 and 𓁼 do not put their pupil in the same place —
//      𓂀 carries the eye high with a tail hanging below, 𓁼 is a bare eye near
//      the baseline — so printed at one baseline they read as two heights. No
//      string assertion can see that; it takes the real face at the real size.
//      Reported as "the eye next to 'Fauci' sits too low; put it where the other
//      one would be".
//
//   2. THE CLICK. The subset row is a plain <div> here (it is a checkbox only on
//      the court page), and its name was plain text, so clicking the name of the
//      set you wanted did nothing. The markup was valid and the `open →` pill
//      worked; the row simply had no answer at the place a reader aims.
//
// THE PUPIL IS FOUND, NOT APPROXIMATED. Flood-filled inward from the border, each
// glyph gives up its enclosed regions, and both contain the same round hole —
// aspect ratio about 1.01 — which is the pupil. Two earlier fixes anchored on the
// middle of the glyph's INKED BOX instead, which for 𓂀 is dragged down by the
// tail, and each of those was reported again.
const {PAGE, demoPage} = require('./harness');

// The pupil's depth below the baseline, in ems, for a glyph in a given font.
// Returned as a positive number: 0.475 means "0.475em above the baseline".
const PUPIL_FINDER = `(ch, font) => {
  const px = 400, N = px * 2, base = Math.round(N * 0.72);
  const c = document.createElement('canvas'); c.width = N; c.height = N;
  const x = c.getContext('2d');
  x.clearRect(0, 0, N, N); x.fillStyle = "#000"; x.font = font;
  x.textAlign = "center"; x.fillText(ch, N / 2, base);
  const d = x.getImageData(0, 0, N, N).data, ink = new Uint8Array(N * N);
  for (let i = 0; i < N * N; i++) ink[i] = d[i * 4 + 3] > 60 ? 1 : 0;
  const out = new Uint8Array(N * N), st = [];
  for (let i = 0; i < N; i++) st.push(i, (N - 1) * N + i, i * N, i * N + N - 1);
  while (st.length) { const q = st.pop();
    if (q < 0 || q >= N * N || out[q] || ink[q]) continue;
    out[q] = 1; const yy = (q / N) | 0, xx = q % N;
    if (xx > 0) st.push(q - 1); if (xx < N - 1) st.push(q + 1);
    if (yy > 0) st.push(q - N); if (yy < N - 1) st.push(q + N); }
  const lab = new Uint8Array(N * N), holes = [];
  for (let p = 0; p < N * N; p++) {
    if (ink[p] || out[p] || lab[p]) continue;
    const q = [p]; lab[p] = 1;
    let n = 0, x0 = N, x1 = 0, y0 = N, y1 = 0;
    while (q.length) { const r = q.pop(); n++;
      const yy = (r / N) | 0, xx = r % N;
      if (xx < x0) x0 = xx; if (xx > x1) x1 = xx;
      if (yy < y0) y0 = yy; if (yy > y1) y1 = yy;
      for (const t of [r - 1, r + 1, r - N, r + N]) {
        if (t < 0 || t >= N * N || ink[t] || out[t] || lab[t]) continue;
        lab[t] = 1; q.push(t); } }
    const w = x1 - x0 + 1, h = y1 - y0 + 1;
    if (n > px * px / 400 && Math.abs(w / h - 1) < 0.15)
      holes.push({area: n, up: (base - (y0 + y1) / 2) / px});
  }
  holes.sort((a, b) => b.area - a.area);
  return holes.length ? holes[0].up : null;
}`;

(async () => {
  const {browser, page, errs} = await demoPage({width: 1440, height: 950});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 800));

  /* A SET WITH A SUBSET IN IT, found in the dataset rather than named here — the
     sample is seeded data and a hardcoded slug outlives the court that had it. */
  const subj = await page.evaluate(() => {
    if (typeof DEMO_OVERLAY === "undefined") return null;
    for (const [slug, c] of Object.entries(DEMO_OVERLAY.courts))
      (c.folders || []).forEach((f, i) => {
        if ((f.folders || []).length && !window.__s)
          window.__s = {slug, path: String(i), name: f.name, child: f.folders[0].name};
      });
    return window.__s || null;
  });
  ok("the offline dataset has a set with a subset filed in it", !!subj,
     subj ? `${subj.slug}/f/${subj.path}: ${subj.name} > ${subj.child}` : "none");
  if (!subj) { await browser.close(); process.exit(fail ? 1 : 0); }

  await page.evaluate(s => { location.hash = "/c/" + s.slug + "/f/" + s.path; }, subj);
  for (let i = 0; i < 20; i++) {
    if (await page.evaluate(() => !!document.querySelector('h1.page-h'))) break;
    await new Promise(r => setTimeout(r, 300));
  }
  await new Promise(r => setTimeout(r, 600));

  /* ---- 1. THE MARK BESIDE THE NAME ------------------------------------------
     Measured for BOTH marks in the heading's own face and size, and then against
     what the page actually applied — because the offset is a class on the span
     and a class can be left off. */
  const head = await page.evaluate(finder => {
    const h1 = document.querySelector('h1.page-h');
    const w = h1 && h1.querySelector('.wedjat');
    if (!w) return null;
    const cs = getComputedStyle(w);
    const pupilOf = eval(finder);
    const font = `${cs.fontWeight} 400px ${cs.fontFamily}`;
    const em = parseFloat(cs.fontSize);
    // `top` is the optical nudge; it is the only thing moving the ink, so it is
    // read back rather than assumed from the class list.
    const shifted = cs.position !== "static" && cs.top !== "auto" ? parseFloat(cs.top) / em : 0;
    return {
      mark: w.textContent, em, shifted,
      classes: w.className,
      open: pupilOf("\u{13080}", font), shut: pupilOf("\u{1307C}", font),
    };
  }, PUPIL_FINDER);
  ok("the set's heading carries its mark", !!head && !!head.mark, JSON.stringify(head));

  if (head && head.open !== null && head.shut !== null) {
    /* THE TWO PUPILS ARE GENUINELY APART IN THE FONT — 0.21em measured. If this
       ever reads near zero the face has changed and the nudge below is wrong,
       which is worth knowing before the assertion about it starts passing for
       the wrong reason. */
    const gap = head.open - head.shut;
    ok("the two marks put their pupil in different places, in this face",
       gap > 0.1, `${gap.toFixed(4)}em apart`);
    /* AND THE PAGE MAKES UP THE DIFFERENCE. `top` is negative (up) on the shut
       mark and absent on the open one, so whichever is drawn, the pupil lands on
       one line. This is the reader's complaint as a number. */
    const drawn = head.mark === "\u{13080}" ? head.open : head.shut;
    const other = head.mark === "\u{13080}" ? head.shut : head.open;
    const nudgeWanted = head.mark === "\u{13080}" ? 0 : -gap;
    ok("the heading's mark is nudged onto the other mark's pupil line",
       Math.abs(head.shifted - nudgeWanted) < 0.02,
       `mark ${head.mark} shifted ${head.shifted.toFixed(4)}em, wanted ${nudgeWanted.toFixed(4)}em`);
    ok("...so both marks would sit at the same height here",
       Math.abs((drawn - head.shifted) - (other - (head.mark === "\u{13080}" ? -gap : 0))) < 0.02,
       `${(drawn - head.shifted).toFixed(4)} vs the other mark's line`);
  }

  /* ---- 2. THE SUBSETS SECTION -----------------------------------------------
     The section, the row, and a click on the name — which is the gesture that
     did nothing. Followed for real: the assertion is the route that results. */
  const sub = await page.evaluate(() => {
    const sec = [...document.querySelectorAll('h2.sec-h')].find(h => /Subsets/.test(h.textContent));
    const row = sec && sec.nextElementSibling && sec.nextElementSibling.querySelector('.folderrow');
    if (!row) return {found: false};
    const a = row.querySelector('.t a.setopen');
    return {
      found: true, hasLink: !!a, href: a && a.getAttribute('href'),
      name: a && a.textContent.trim(),
      // A link a reader can see is one: the pointer has to change over it.
      cursor: a && getComputedStyle(a).cursor,
      pill: !!row.querySelector('a.pill.foldopen'),
    };
  });
  ok("the set page lists its subsets", sub.found, JSON.stringify(sub));
  ok("...and the subset's NAME is a link, which is where a reader clicks",
     sub.hasLink, JSON.stringify(sub));
  ok("...pointing at that subset's own page", /^#\/c\/[a-z0-9-]+\/f\/[\w.]+$/.test(sub.href || ""),
     String(sub.href));
  ok("...and reads as clickable under the pointer", sub.cursor === "pointer", String(sub.cursor));
  ok("...while `open →` stays, because the whole row is a way in", sub.pill);

  /* FOLLOWED, NOT JUST PRESENT. A link with a href the router does not resolve
     is the same "nothing happens" from the reader's side, so the click is made
     and the page that comes back is checked. */
  const went = await page.evaluate(() => {
    const sec = [...document.querySelectorAll('h2.sec-h')].find(h => /Subsets/.test(h.textContent));
    const a = sec.nextElementSibling.querySelector('.folderrow .t a.setopen');
    const was = location.hash, want = a.getAttribute('href').slice(1);
    a.click();
    return {was, want};
  });
  await new Promise(r => setTimeout(r, 900));
  const landed = await page.evaluate(() => ({
    hash: location.hash,
    heading: (document.querySelector('h1.page-h') || {}).textContent || "",
  }));
  ok("clicking the subset's name goes to it", landed.hash === "#" + went.want,
     `${went.was} -> ${landed.hash}, wanted #${went.want}`);
  ok("...and the page that arrives is that set's", landed.heading.includes(subj.child),
     `heading "${landed.heading.slice(0, 50)}" should name "${subj.child}"`);

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
