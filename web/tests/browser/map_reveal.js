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
      y0: parseFloat(t.dataset.y0),
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

  /* 2. THE PUPIL, AND THE ONLY HONEST WAY TO MEASURE IT.
        𓂀 is a whole wedjat — almond, brow, and the tail curling below — while
        𓁼 is an eye alone. Drawn at one baseline the two pupils sit about a fifth
        of an em apart, so the code raises the shut glyph by 0.22em.
        TWO OBVIOUS PROBES BOTH LIE. getBBox() on SVG <text> returns the FONT's
        line box, not the ink: measured here, 𓂀 and 𓁼 report byte-identical
        top and height and differ only in advance width, so a bbox comparison
        cannot see the pupil move at all and passes whatever the nudge is. And
        the ink centre is no better — 𓂀's tail drags its centre down, so aligning
        centres would deliberately misalign the eyes.
        SO ASK THE PIXELS WHICH SHIFT OVERLAYS THEM. Both glyphs are drawn to a
        canvas at eight times the em, reduced to a per-row ink profile, and
        correlated across every offset. The peak is the shift that makes the two
        eyes coincide — a self-calibrating measurement of the constant the code
        applies, which is exactly what would go stale if the face changed. */
  const nudge = await page.evaluate(() => {
    const t = document.querySelector('.mapwrap svg text.mset');
    const cs = getComputedStyle(t);
    const px = Math.round(parseFloat(cs.fontSize) * 8), N = px * 3;
    const c = document.createElement('canvas'); c.width = N; c.height = N;
    const x = c.getContext('2d');
    const prof = ch => {
      x.clearRect(0, 0, N, N); x.fillStyle = "#000";
      x.font = `${cs.fontWeight} ${px}px ${cs.fontFamily}`;
      x.textAlign = "center"; x.fillText(ch, N / 2, N * 0.7);
      const d = x.getImageData(0, 0, N, N).data, p = new Float64Array(N);
      for (let yy = 0; yy < N; yy++) { let s = 0;
        for (let xx = 0; xx < N; xx++) s += d[(yy * N + xx) * 4 + 3]; p[yy] = s; }
      return p;
    };
    const A = prof("\u{13080}"), B = prof("\u{1307C}");
    let best = 0, bestv = -1;
    for (let d = -px; d <= px; d++) {
      let s = 0;
      for (let yy = 0; yy < N; yy++) { const j = yy + d; if (j >= 0 && j < N) s += A[yy] * B[j]; }
      if (s > bestv) { bestv = s; best = d; }
    }
    // best > 0 means the shut glyph's ink sits that far BELOW the open one's, so
    // that is how far up it has to be moved. Reported in ems, like the constant.
    return {em: best / px, px, ink: bestv > 0};
  });
  ok("both marks render as real ink in the page's own face", nudge.ink);
  /* THE TOLERANCE IS HALF A PIXEL at the size the map draws these, wide enough
     for hinting to differ between machines and far too tight to survive the
     nudge being dropped (0.00) or reversed (-0.22). Measured on this face:
     0.2154 against the 0.22 the code applies. */
  ok("the coded nudge is the one that actually overlays the two eyes",
     Math.abs(nudge.em - 0.22) < 0.03,
     `measured ${nudge.em.toFixed(4)}em, code uses 0.22em`);

  const subject = a.sets[0];
  ok("a set carries its open baseline and its em", isFinite(subject.y0) && isFinite(subject.es),
     `y0=${subject.y0} es=${subject.es}`);
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
  /* AND THE BASELINE MOVED BY THAT MEASURED AMOUNT, in the right direction: the
     shut mark is drawn higher, by the shift the pixels just asked for. This is
     the runtime half — the constant is right AND paint() applies it. */
  const shut = after.mark === SHUT_MARK ? after : before;
  const open = after.mark === SHUT_MARK ? before : after;
  const applied = (open.y - shut.y) / open.es;
  ok("...and paint moves the baseline by that same shift, upward",
     Math.abs(applied - nudge.em) < 0.03,
     `applied ${applied.toFixed(4)}em, measured ${nudge.em.toFixed(4)}em`);
  /* THE RING TRAVELS WITH IT. It is drawn centred on the nudged glyph; left at
     the filed position it would sit a fifth of an em low and the mark would
     poke through the top of its own outline. */
  ok("...and the ring travels with the glyph",
     Math.abs((open.ring - shut.ring) - (open.y - shut.y)) < 0.6,
     `glyph moved ${(open.y-shut.y).toFixed(2)}, ring moved ${(open.ring-shut.ring).toFixed(2)}`);
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

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : `\nALL PASS (${a.sets.length} set(s) on ${slug})`);
  process.exit(fail ? 1 : 0);
})();
