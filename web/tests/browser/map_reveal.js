// Opening a set on the map, in a real browser.
//
// WHY THIS NEEDS A BROWSER AND THE SOURCE HARNESS DOES NOT COVER IT.
// mapreveal_test.js runs subtreeOf/revealed/defaultReveal over a fake layout and
// proves the ARITHMETIC. It cannot prove that the arithmetic reaches the screen:
// the marks are <text> nodes rewritten by paint(), the dimming is a class on
// nodes paint() also owns, and put() replaces the whole SVG underneath both.
//
// THAT GAP HAS ALREADY BITTEN ONCE, in this same corner of the file. A filter
// retarget keyed a toggle on `.eyeopen`, a class the set rows do not carry — the
// open eye vanished from the page and all fifty-three source harnesses stayed
// green, because every one of them asserts a shape in the source rather than a
// pixel on the screen. It was found by a probe that happened to return null.
//
// So the three things measured here are the three that only exist at runtime:
//   1. the map opens with something revealed, when the court filed a 𓂀 set;
//   2. clicking a set reveals its contents, and re-clicking puts them back;
//   3. the mark on the set swaps between 𓂀 and 𓁼 AND THE PUPIL DOES NOT MOVE —
//      which is a measurement of two glyphs' baselines in the real font and is
//      not answerable from the source at all.
//
// NOTHING HERE HARDCODES A COURT OR A SET. The docket is seeded data that
// changes; the check finds a court that actually has a set on its map and skips
// cleanly if none does, because a check that fails when the demo data is
// reshaped teaches people to ignore it.
const {PAGE, demoPage} = require('./harness');

const SET_MARK = "\u{13080}";   // 𓂀 — revealed
const SHUT_MARK = "\u{1307C}";  // 𓁼 — concealed

(async () => {
  const {browser, page, errs} = await demoPage({width: 1440, height: 950});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 800));
  /* EVERY DEMO COURT, not the ones the directory links. `annex` is the only
     offline court with a claim-born set and it is not on the front page — the
     first version of this check read the directory's links, found orem and
     ledger, and reported that no court on this chain draws a set. */
  const slugs = await page.evaluate(() =>
    typeof DEMO_OVERLAY !== "undefined" ? Object.keys(DEMO_OVERLAY.courts) : []);
  ok("the offline dataset offers courts to look at", slugs.length > 0);

  // Find a court whose map actually draws a set. Sets are the subject here; a
  // court with none would pass every assertion vacuously.
  let slug = null, marks = 0;
  for (const s of slugs) {
    await page.evaluate(x => { location.hash = "/c/" + x + "/map"; }, s);
    for (let i = 0; i < 20; i++) {
      if (await page.evaluate(() => !!document.querySelector('.mapwrap svg'))) break;
      await new Promise(r => setTimeout(r, 300));
    }
    await new Promise(r => setTimeout(r, 400));
    marks = await page.evaluate(() => document.querySelectorAll('.mapwrap svg text.mset').length);
    if (marks > 0) { slug = s; break; }
  }
  ok("a court on this chain draws a set on its map", !!slug,
     slug ? `${slug}, ${marks} set(s)` : `looked at ${slugs.length} court(s)`);
  if (!slug) { console.log("\nno set to open; nothing to measure"); await browser.close(); process.exit(fail ? 1 : 0); }

  const read = () => page.evaluate(() => {
    const svg = document.querySelector('.mapwrap svg');
    const sets = [...svg.querySelectorAll('text.mset')].map(t => ({
      fid: t.dataset.fid,
      // The tspan, not textContent: the <title> is a sibling and would come with it.
      mark: (t.querySelector(".msetmark") || {}).textContent,
      says: (t.querySelector("title") || {}).textContent,
      y: parseFloat(t.getAttribute("y")),
      cy: parseFloat(t.dataset.cy),
      es: parseFloat(t.dataset.es),
      /* The ring's centre, read back off the circle: it is drawn around the
         nudged glyph, so it has to travel with it. */
      ring: (c => c ? parseFloat(c.getAttribute("cy")) : null)(
        svg.querySelector(`circle.msetring[data-fid="${t.dataset.fid}"]`)),
    }));
    const dimmed = el => !!el.closest('.dim') || el.classList.contains('dim');
    const lit = sel => [...svg.querySelectorAll(sel + '.selected')];
    return {
      sets,
      lit: lit('.mfold-a').map(a => a.dataset.fid),
      litClaims: lit('.mnode-a').map(a => a.dataset.id),
      dimmed: svg.querySelectorAll('.dim').length,
      /* THE ONE INVARIANT THAT MUST HOLD IN EVERY STATE: nothing the reader
         selected may be dimmed. The dim is "outside the spotlight"; a selected
         node in it is the two halves of paint() disagreeing about what is open. */
      litButDim: [...lit('.mfold-a'), ...lit('.mnode-a')].filter(dimmed).length,
      nodes: svg.querySelectorAll('.mnode-a').length,
    };
  });

  /* 1. THE OPENING VIEW. Whatever the court filed, the marks on screen have to
        agree with the sets that are lit — a set drawn 𓂀 but not selected, or
        selected but drawn 𓁼, is the page contradicting itself. */
  const a = await read();
  const openMarks = a.sets.filter(s => s.mark === SET_MARK).map(s => s.fid).sort();
  ok("every mark on the map is one of the two the realm accepts",
     a.sets.every(s => s.mark === SET_MARK || s.mark === SHUT_MARK),
     JSON.stringify(a.sets.map(s => s.mark)));
  ok("the open marks are exactly the lit sets, at rest",
     openMarks.join(" ") === [...a.lit].sort().join(" "),
     `marks=[${openMarks}] lit=[${[...a.lit].sort()}]`);

  /* THE OPENING VIEW IS NOT VACUOUS. A court that filed a set 𓂀 must open with
     it revealed — that is the entire meaning of the mark, and it is the one
     thing here that no amount of clicking would demonstrate. Asked of the
     DATASET rather than of the page, so it is the fixture's declaration being
     checked against the render and not the render against itself. */
  const declaredOpen = await page.evaluate(x =>
    ((DEMO_OVERLAY.courts[x] || {}).folders || []).filter(f => f.focus).map(f => f.name), slug);
  if (declaredOpen.length) {
    ok("a court that filed a set 𓂀 opens with it revealed",
       a.lit.length > 0, `declared [${declaredOpen}] but nothing is lit`);
    ok("...and with its contents, not the set alone",
       a.lit.length + a.litClaims.length > declaredOpen.length,
       `${a.lit.length} set(s) + ${a.litClaims.length} claim(s) for ${declaredOpen.length} declared`);
  } else {
    ok("this court filed nothing 𓂀, so it opens on nothing", a.lit.length === 0);
  }

  /* 2. THE PUPIL SITS IN THE MIDDLE OF ITS RING, whichever mark is drawn.
        Reported three times as the eye being in the wrong place, and each of the
        first two fixes anchored on something that is not the pupil.
        WHY THE OBVIOUS PROBES ALL MISS IT.
          - getBBox() on SVG <text> returns the FONT's line box, not the ink: 𓂀
            and 𓁼 report byte-identical top and height, so it cannot see the mark
            move at all.
          - The middle of the INKED BOX is wrong for 𓂀, which hangs a tail well
            below the eye — centring the box puts the tail in the middle and
            lifts the eye out of it. That is the fix that shipped and was
            reported again.
          - Correlating the two glyphs' ink profiles finds the shift that best
            overlays their MASS, which is dragged by that same tail.
        SO FIND THE PUPIL ITSELF. Rendered at 400px and flood-filled inward from
        the border, each glyph gives up its ENCLOSED regions — and both contain
        the same round hole, aspect ratio 1.01, which is the pupil. Its centre is
        the only landmark here that means what the reader means. */
  const pupil = await page.evaluate(() => {
    const t = document.querySelector('.mapwrap svg text.mset');
    const cs = getComputedStyle(t);
    const px = 400, N = px * 2, base = Math.round(N * 0.72);
    const c = document.createElement('canvas'); c.width = N; c.height = N;
    const x = c.getContext('2d');
    const find = ch => {
      x.clearRect(0, 0, N, N); x.fillStyle = "#000";
      x.font = `${cs.fontWeight} ${px}px ${cs.fontFamily}`;
      x.textAlign = "center"; x.fillText(ch, N / 2, base);
      const d = x.getImageData(0, 0, N, N).data, ink = new Uint8Array(N * N);
      for (let i = 0; i < N * N; i++) ink[i] = d[i * 4 + 3] > 60 ? 1 : 0;
      // white reachable from the border is OUTSIDE; what is left is enclosed
      const out = new Uint8Array(N * N), st = [];
      for (let i = 0; i < N; i++) st.push(i, (N - 1) * N + i, i * N, i * N + N - 1);
      while (st.length) { const q = st.pop();
        if (q < 0 || q >= N * N || out[q] || ink[q]) continue;
        out[q] = 1; const yy = (q / N) | 0, xx = q % N;
        if (xx > 0) st.push(q - 1); if (xx < N - 1) st.push(q + 1);
        if (yy > 0) st.push(q - N); if (yy < N - 1) st.push(q + N); }
      const lab = new Uint8Array(N * N), holes = [];
      for (let p0 = 0; p0 < N * N; p0++) {
        if (ink[p0] || out[p0] || lab[p0]) continue;
        const q = [p0]; lab[p0] = 1;
        let n = 0, x0 = N, x1 = 0, y0 = N, y1 = 0;
        while (q.length) { const r = q.pop(); n++;
          const yy = (r / N) | 0, xx = r % N;
          if (xx < x0) x0 = xx; if (xx > x1) x1 = xx;
          if (yy < y0) y0 = yy; if (yy > y1) y1 = yy;
          for (const t2 of [r - 1, r + 1, r - N, r + N]) {
            if (t2 < 0 || t2 >= N * N || ink[t2] || out[t2] || lab[t2]) continue;
            lab[t2] = 1; q.push(t2); } }
        const w = x1 - x0 + 1, h = y1 - y0 + 1;
        // Round, and a real feature rather than an antialiasing speck.
        if (n > px * px / 400 && Math.abs(w / h - 1) < 0.15)
          holes.push({area: n, mid: ((y0 + y1) / 2 - base) / px});
      }
      holes.sort((a, b) => b.area - a.area);
      return holes.length ? holes[0].mid : null;
    };
    return {open: find("\u{13080}"), shut: find("\u{1307C}")};
  });
  ok("the pupil is findable in both marks, as an enclosed round hole",
     pupil.open !== null && pupil.shut !== null, JSON.stringify(pupil));

  /* THE CODED OFFSET IS THE PUPIL'S OWN DEPTH, so the baseline it produces puts
     that pupil on the point the badge is drawn around. Checked against the
     constants the page ships: the day the face changes, this says so. */
  const coded = await page.evaluate(() => ({open: MSET_PUPIL_OPEN, shut: MSET_PUPIL_SHUT}));
  for (const which of ["open", "shut"]) {
    const off = coded[which] + pupil[which];   // 0 when the pupil is on the ring centre
    ok(`the ${which} mark's pupil is centred in its ring`, Math.abs(off) < 0.03,
       `${(off > 0 ? "+" : "")}${off.toFixed(4)}em off centre `
       + `(code ${coded[which]}, pupil at ${(-pupil[which]).toFixed(4)})`);
  }
  /* AND SO THE EYE DOES NOT MOVE AS IT OPENS, which is the property that was
     asked for. It follows from both being centred, and is stated separately
     because a check should fail on the words it was given. */
  ok("...so the eye does not jump as it opens",
     Math.abs((coded.open + pupil.open) - (coded.shut + pupil.shut)) < 0.04,
     `open ${(coded.open + pupil.open).toFixed(4)} vs shut ${(coded.shut + pupil.shut).toFixed(4)}`);

  /* AND EVERY MARK ON THE PAGE IS ACTUALLY DRAWN THERE. The two checks above
     compare the constants against the ink; this one compares the DRAWN baseline
     against the constants, which is the step where a mark can still come out
     wrong — one offset used for both states draws a correct number in the wrong
     place, and reading the constants alone would never see it. */
  for (const st of a.sets) {
    const want = coded[st.mark === SET_MARK ? "open" : "shut"];
    ok(`set ${st.fid} is drawn on the baseline its mark calls for`,
       Math.abs((st.y - st.cy) / st.es - want) < 0.01,
       `drawn ${((st.y - st.cy) / st.es).toFixed(4)}em, want ${want}`);
  }

  const subject = a.sets[0];
  ok("a set carries its ring centre and its em", isFinite(subject.cy) && isFinite(subject.es),
     `cy=${subject.cy} es=${subject.es}`);
  const before = subject;
  await page.evaluate(fid => {
    document.querySelector(`.mapwrap svg .mfold-a[data-fid="${fid}"]`).dispatchEvent(
      new MouseEvent("click", {bubbles: true, cancelable: true}));
  }, subject.fid);
  await new Promise(r => setTimeout(r, 350));
  const b = await read();
  const after = b.sets.find(s => s.fid === subject.fid);

  ok("clicking a set swaps its mark", after.mark !== before.mark,
     `${before.mark} -> ${after.mark}`);
  ok("...and it is the other one of the pair, not a third thing",
     [SET_MARK, SHUT_MARK].includes(after.mark));
  /* AND paint() APPLIES THE SAME TWO OFFSETS the first draw did, so a swap
     lands the new glyph centred rather than wherever the old one was. */
  const shut = after.mark === SHUT_MARK ? after : before;
  const open = after.mark === SHUT_MARK ? before : after;
  const applied = (open.y - shut.y) / open.es;
  ok("...and paint moves the baseline by the difference between them",
     Math.abs(applied - (coded.open - coded.shut)) < 0.02,
     `applied ${applied.toFixed(4)}em, coded ${(coded.open - coded.shut).toFixed(4)}em`);
  /* THE RING DOES NOT MOVE AT ALL ANY MORE. It used to chase the glyph because
     the glyph was drawn off-centre; both marks are centred on it now, so a ring
     that shifts means one of them has come loose again. */
  ok("...and the ring stays put, because it no longer has to chase anything",
     open.ring === shut.ring, `${shut.ring} -> ${open.ring}`);
  ok("...and the badge still says which state it is in",
     !!after.says && after.says !== before.says, `"${before.says}" -> "${after.says}"`);

  /* 3. THE CONTENTS. THE DIM IS A SPOTLIGHT, NOT A CURTAIN — with nothing
        selected the map is evenly lit and NOTHING is dimmed, and selecting is
        what darkens everything outside the selection. The first version of this
        check asserted the opposite ("opening reveals more") and failed on a
        court whose set is filed concealed: dim went 0 -> 6, which is the feature
        working. Direction depends on which way the click went. */
  const opened = after.mark === SET_MARK;
  ok(opened ? "opening a set puts the map under a spotlight"
            : "shutting the last open set lifts the spotlight",
     opened ? b.dimmed > a.dimmed : b.dimmed < a.dimmed,
     `dim ${a.dimmed} -> ${b.dimmed} of ${a.nodes} claim node(s)`);
  /* AND IT TOOK ITS CONTENTS WITH IT, which is the request this feature answers:
     a set that opens and leaves its claims shut has answered a different
     question. annex's set holds claims, so opening it must light more than the
     set itself. */
  if (opened) {
    ok("...and the set's contents are lit with it",
       b.lit.length + b.litClaims.length > 1,
       `${b.lit.length} set(s) + ${b.litClaims.length} claim(s) lit`);
  }
  ok("nothing selected is dimmed, at rest", a.litButDim === 0, String(a.litButDim));
  ok("...nor after a click", b.litButDim === 0, String(b.litButDim));

  // And back: a second click returns the map to exactly the state it opened in.
  await page.evaluate(fid => {
    document.querySelector(`.mapwrap svg .mfold-a[data-fid="${fid}"]`).dispatchEvent(
      new MouseEvent("click", {bubbles: true, cancelable: true}));
  }, subject.fid);
  await new Promise(r => setTimeout(r, 350));
  const c = await read();
  ok("re-clicking puts the mark back", c.sets.find(s => s.fid === subject.fid).mark === before.mark);
  ok("...and puts the map back", c.dimmed === a.dimmed, `${a.dimmed} -> ${b.dimmed} -> ${c.dimmed}`);
  ok("...and the lit sets are the ones they were",
     [...c.lit].sort().join(" ") === [...a.lit].sort().join(" "));

  /* 4. THE REDRAW. put() replaces the SVG outright; switching titles↔ids used to
        drop every class paint had set, which is invisible until you look. */
  const btn = await page.$('#mt-ids') || await page.$('#mt-titles');
  if (btn) {
    await page.evaluate(() => {
      const el = document.getElementById("mt-ids") || document.getElementById("mt-titles");
      if (el && el.getAttribute("aria-pressed") === "true")
        (document.getElementById("mt-titles") || el).click();
      else if (el) el.click();
    });
    await new Promise(r => setTimeout(r, 400));
    const d = await read();
    ok("a redraw keeps the marks it had", d.sets.filter(s => s.mark === SET_MARK).length
       === a.sets.filter(s => s.mark === SET_MARK).length,
       `${a.sets.filter(s=>s.mark===SET_MARK).length} -> ${d.sets.filter(s=>s.mark===SET_MARK).length}`);
    ok("...and the selection with them", [...d.lit].sort().join(" ") === [...a.lit].sort().join(" "),
       `[${[...a.lit].sort()}] -> [${[...d.lit].sort()}]`);
  }

  /* 5. A SET OPENS ITS SUBSETS, WHICH IS THE HALF ANNEX CANNOT SHOW. The court
        with the mark has claims filed under it and no nested folder; the court
        with a nested folder has no claim-born set. So the mark, the pupil and
        the ring are measured above on annex, and the descent is measured here on
        whichever court actually nests one folder inside another.
        THIS EXISTS BECAUSE THE FIRST VERSION OF THE FEATURE PASSED EVERYTHING
        WITHOUT IT. The layout returns boxes, not tree nodes, so the reveal walked
        an empty `kids` and opened nothing below the set — and the mutation that
        reproduces it (carrying no child keys onto the boxes) was caught by
        neither harness until this phase existed, because on annex there was no
        subset for it to lose. */
  const nest = await page.evaluate(() => {
    if (typeof DEMO_OVERLAY === "undefined") return null;
    for (const [slug, c] of Object.entries(DEMO_OVERLAY.courts))
      for (const f of (c.folders || []))
        if ((f.folders || []).length) return {slug, parent: f.name, child: f.folders[0].name};
    return null;
  });
  ok("the offline dataset nests one folder inside another somewhere", !!nest,
     nest ? `${nest.slug}: ${nest.parent} > ${nest.child}` : "none");
  if (nest) {
    await page.evaluate(x => { location.hash = "/c/" + x + "/map"; }, nest.slug);
    for (let i = 0; i < 20; i++) {
      if (await page.evaluate(() => !!document.querySelector('.mapwrap svg .mfold-a'))) break;
      await new Promise(r => setTimeout(r, 300));
    }
    await new Promise(r => setTimeout(r, 500));
    // Found by the name it is drawn under, so nothing here pins an index that
    // the layout is free to reorder.
    const hit = await page.evaluate(n => {
      const find = name => [...document.querySelectorAll('.mapwrap svg .mfold-a')]
        .find(a => (a.textContent || "").includes(name));
      const p = find(n.parent), c = find(n.child);
      if (!p || !c) return {found: false, p: !!p, c: !!c};
      p.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true}));
      return {found: true, pfid: p.dataset.fid, cfid: c.dataset.fid};
    }, nest);
    ok("both the set and its subset are drawn on the map", hit.found, JSON.stringify(hit));
    if (hit.found) {
      await new Promise(r => setTimeout(r, 350));
      const e = await read();
      ok("opening a set opens the set filed inside it",
         e.lit.includes(hit.cfid), `lit=[${e.lit}] parent=${hit.pfid} child=${hit.cfid}`);
      ok("...and the parent with it", e.lit.includes(hit.pfid), `lit=[${e.lit}]`);
      ok("...and nothing lit is dimmed", e.litButDim === 0, String(e.litButDim));
    }
  }

  /* 6. THE CAMERA STOPS HALFWAY. Measured on the real thing rather than read off
        the source, because the number that matters is where the viewport ends up
        after the glide settles — a blend applied to the wrong pair of
        coordinates, or a tween that overshoots and stays, both produce correct
        -looking source and a map that jumps.
        MEASURED AS A RATIO OF THE TRAVEL, so it holds at any zoom and on any
        court: where did the camera start, where is the node, where did the
        camera stop. */
  const glide = await page.evaluate(async () => {
    const svg = document.querySelector('.mapwrap svg');
    const wrap = svg.parentElement;
    // The viewport centre in the SVG's own units, before and after.
    const centre = () => {
      const r = wrap.getBoundingClientRect();
      const pt = svg.createSVGPoint();
      pt.x = r.left + r.width / 2; pt.y = r.top + r.height / 2;
      const m = svg.getScreenCTM().inverse();
      const p = pt.matrixTransform(m);
      return {x: p.x, y: p.y};
    };
    const far = [...svg.querySelectorAll('.mnode-a')]
      .map(a => ({a, r: a.getBoundingClientRect()}))
      .sort((p, q) => q.r.top - p.r.top)[0];      // something well off centre
    if (!far) return null;
    const before = centre();
    const t = far.a.getBoundingClientRect();
    const pt = svg.createSVGPoint();
    pt.x = t.left + t.width / 2; pt.y = t.top + t.height / 2;
    const target = pt.matrixTransform(svg.getScreenCTM().inverse());
    far.a.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true}));
    await new Promise(r => setTimeout(r, 1400));   // let the glide settle
    const after = centre();
    const travel = Math.hypot(target.x - before.x, target.y - before.y);
    const moved  = Math.hypot(after.x - before.x, after.y - before.y);
    return {travel, moved, ratio: travel > 1 ? moved / travel : null};
  });
  ok("there is a node far enough off centre to measure a move against",
     glide && glide.ratio !== null, JSON.stringify(glide));
  if (glide && glide.ratio !== null) {
    /* MEASURED 0.500 HERE, and the band is wide anyway: tz can raise z to clear
       the LOD line, and when it does, the SVG units this ratio is computed in
       change under it. Wide enough for that, and nowhere near either failure it
       exists to catch — measured at 1.000 when the blend is removed and 0.000
       when the camera is pinned. */
    ok("the camera stops about halfway to the node it was given",
       glide.ratio > 0.25 && glide.ratio < 0.75,
       `moved ${glide.moved.toFixed(1)} of ${glide.travel.toFixed(1)} = ${glide.ratio.toFixed(3)}`);
  }

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : `\nALL PASS (${a.sets.length} set(s) on ${slug})`);
  process.exit(fail ? 1 : 0);
})();
