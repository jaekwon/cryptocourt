// Clicking a claim node grows it, with a spring, in place.
//
// WHY THIS EXISTS. Asked for as "when i click a claim node i want it to enlarge
// w/ quick transition 'boing' so i can read the title better". Every part of
// that is a rendered fact and none of it is visible in the source: whether the
// node grows, whether the growth overshoots or just eases, whether the title
// grows WITH the box or stays its old size inside a bigger frame, and whether
// the thing scales in place or launches across the drawing.
//
// THE ONE THAT WOULD SHIP BROKEN IS transform-box. An SVG element's
// transform-origin resolves against the VIEWBOX unless transform-box is
// fill-box — so `transform-origin:center` without it means the centre of the
// whole map, and a scale(1.18) about that point throws the node a fifth of the
// map away from where the reader clicked. It looks like a bug in the layout,
// not like a missing one-line property, and no source harness can see it.
//
// WHAT IT DOES NOT COVER. Layout-dependent overlap, and it does not bound the
// spring's size — see the sweep's own comment. SVG has no z-index, so a grown
// node cannot paint above a later sibling and reordering the DOM to fake it
// would scramble tab order; the sweep therefore counts obscuring overlap so a
// tighter layout surfaces as a number rather than as a screenshot somebody
// happens to look at. On this docket it stays incidental even at 2.0x.
//
// ABLATED, each on its own arm:
//   dropping transform-box:fill-box     the in-place assertion fails (origin is the map's)
//   easing changed to plain `ease`      the overshoot assertion fails, growth still passes
//   dropping .selected{transform:...}   growth and title-growth fail, origin still passes
//   dropping the global reduce rule     only the reduced-motion arm fails
//
// That last one is worth reading twice. The first version of this file shipped
// with a per-class `@media (prefers-reduced-motion: reduce){ .mnode-a{...} }`
// beside the transition, and deleting it changed NOTHING — the stylesheet
// already carries `*{transition:none!important}` under the same query, which
// outranks it. The rule was dead on arrival and the ablation is what said so.
// So the arm below is aimed at the global rule, which is what actually runs.
const {PAGE, demoPage} = require('./harness');
// MAPK.vov, read out of the page rather than retyped: it is the overhang a badged
// node reserves below its frame, and the transform-origin bound below is derived
// from it. A number copied here would agree with the map on the day it was copied.
const MAPKVOV = (() => {
  const src = require('fs').readFileSync(
    require('path').join(__dirname, '..', '..', 'index.html'), 'utf8');
  const m = /vrow:\s*\d+,\s*vov:\s*(\d+)/.exec(src);
  if (!m) throw new Error("map_boing: MAPK.vov not found in web/index.html");
  return +m[1];
})();

(async () => {
  const {browser, page, errs} = await demoPage({width: 1440, height: 950});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  const slug = await (async () => {
    await page.goto(PAGE + '#/', {waitUntil: 'networkidle2'});
    await new Promise(r => setTimeout(r, 800));
    return page.evaluate(() => [...document.querySelectorAll('a[href^="#/c/"]')]
      .map(x => x.getAttribute('href'))
      .map(h => (h.match(/^#\/c\/([a-z0-9-]+)$/) || [])[1]).find(Boolean) || null);
  })();
  ok("the directory offers a court to open", !!slug, slug || "none");
  if (!slug) { await browser.close(); process.exit(1); }

  const openMap = async () => {
    await page.goto(PAGE + '#/c/' + slug + '/map', {waitUntil: 'networkidle2'});
    for (let i = 0; i < 20; i++) {
      if (await page.evaluate(() => !!document.querySelector('.mnode-a'))) break;
      await new Promise(r => setTimeout(r, 400));
    }
    await new Promise(r => setTimeout(r, 2200));
  };
  // A CANCELABLE CLICK, or preventDefault cannot stop the <a> and the page
  // navigates to the claim instead of selecting on the map. The first version of
  // this probe used the default (cancelable:false) and reported that the node
  // had vanished — it had: the map was no longer on screen.
  const clickNode = (i) => page.evaluate(k => {
    document.querySelectorAll('.mnode-a')[k]
      .dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
  }, i);
  /* THE CAMERA, MEASURED OFF THE viewBox — which is what the camera IS. apply()
     writes `${cx-w/2} ${cy-h/2} ${w} ${h}` with w = fit.w/z, so z is exactly
     proportional to 1/width and a ratio of two widths is a ratio of two zooms,
     with no 1.35 spring and no font rounding anywhere in it.
     TITLE PIXELS WERE THE FIRST INSTRUMENT HERE and they cannot carry the
     staged-zoom arms below: the spring supplies most of the growth on this
     fixture, so the whole difference between "half the zoom" and "all of it"
     was 33px against 38px, both standing on a `before` of 20px that is itself
     a rounded rect height. The title arms are still worth having — they are the
     reader's question — but "how far did the camera go" needs the camera. */
  const camW = () => page.evaluate(() => {
    const el = document.querySelector('.mapwrap svg');
    const vb = el && el.getAttribute('viewBox');
    return vb ? parseFloat(vb.trim().split(/\s+/)[2]) : null;
  });
  const selTitleH = () => page.evaluate(() => {
    const t = document.querySelector('.mnode-a.selected text.mtitle');
    return t ? t.getBoundingClientRect().height : null;
  });

  await openMap();
  const n = await page.evaluate(() => document.querySelectorAll('.mnode-a').length);
  ok("the map drew claim nodes to click", n >= 3, "nodes=" + n);

  // ------------------------------------------------------------ grows, and springs
  /* MEASURED OFF THE TRANSFORM, NOT OFF THE SCREEN, and the first version of
     this check got that wrong. getBoundingClientRect().width includes the map's
     own zoom, and selecting a node now moves the CAMERA too — so the on-screen
     width grew 1.898x from a 1.35 spring times a 1.406 camera, and the check
     failed on a value that was correct. The node's own scale is the first entry
     of its computed matrix; the camera is not in it. */
  const scaleOf = () => page.evaluate(() => {
    const a = document.querySelector('.mnode-a.selected') || document.querySelector('.mnode-a');
    const m = getComputedStyle(a).transform;
    if (!m || m === "none") return 1;
    const n = m.match(/matrix\(([^)]+)\)/);
    return n ? parseFloat(n[1].split(",")[0]) : NaN;
  });
  /* THE PEAK OF THE FLIGHT, NOT ONE SAMPLE PARTWAY THROUGH IT. Both overshoot
     arms below used to read the transform once, 130ms after the click, and that
     went red once in four runs on an unchanged page: the transition can start a
     frame or two late, so the lone sample lands before the curve has passed 1
     and an overshoot that did happen reads as absent (measured: mid 1.33558
     against a settled 1.35 — a fail on a build with a perfectly good spring).
     The claim is "at some point it goes past its landing", so the instrument is
     a MAX over the flight: the same assertion, sampled where it can be seen.
     Still a real measurement of a real overshoot — a plain ease never exceeds
     its target at any sample, so it fails this exactly as it failed the old
     one. */
  const peakOf = async (read, ms = 300) => {
    let hi = 0;
    for (let t = 0; t < ms; t += 20) {
      hi = Math.max(hi, await read());
      await new Promise(r => setTimeout(r, 20));
    }
    return hi;
  };
  const before = await page.evaluate(() => {
    const a = document.querySelector('.mnode-a'), r = a.getBoundingClientRect();
    const cs = getComputedStyle(a), t = a.querySelector('text.mtitle');
    return {w: r.width, transformBox: cs.transformBox, origin: cs.transformOrigin,
            dur: cs.transitionDuration, ease: cs.transitionTimingFunction,
            titleH: t ? t.getBoundingClientRect().height : null,
            boxW: a.querySelector('.mnode').getBBox().width,
            boxH: a.querySelector('.mnode').getBBox().height};
  });
  const scale0 = await scaleOf();
  const vb0 = await camW();
  await clickNode(0);
  // Mid-flight. A back-out curve goes PAST its destination somewhere in here; a
  // plain ease never does. That difference is the whole "boing" — and it has to
  // be read off the transform, because the camera glide is moving at the same
  // time and would otherwise be indistinguishable from the spring.
  const midScale = await peakOf(scaleOf);
  await new Promise(r => setTimeout(r, 900));
  const scale1 = await scaleOf();
  const after = await page.evaluate(() => {
    const a = document.querySelector('.mnode-a.selected');
    if (!a) return null;
    const t = a.querySelector('text.mtitle');
    return {w: a.getBoundingClientRect().width,
            titleH: t ? t.getBoundingClientRect().height : null};
  });
  ok("clicking a node selects it on the map, without leaving for its page", !!after);
  if (!after) { await browser.close(); process.exit(1); }

  // Bounds as LITERALS around the authored 1.35 — spelling them as the CSS value
  // would move with it and pass at 1.0.
  ok(`the node's own scale is up (${scale0} -> ${scale1})`,
     Math.abs(scale0 - 1) < 0.01 && scale1 > 1.28 && scale1 < 1.45);
  ok(`...and the spring overshoots its landing (mid ${midScale} > settled ${scale1})`,
     midScale > scale1);
  /* THE READER'S ACTUAL QUESTION, and it is a RATIO because an absolute floor
     could not tell the two mechanisms apart. First written as `>= 28px`, which
     passed either way: on this fixture the scan-size zoom already lands the
     picked title at exactly 28 and the reading-size zoom at 38, so the threshold
     sat on the boundary and certified nothing. Ablating readSelPx back to readPx
     is what exposed it — the arm stayed green.
     A ratio against the SAME map's unselected title separates them. The spring
     alone can only ever deliver its own 1.35; anything past that came from the
     camera, which is the half the transform cannot do. 1.6 therefore fails a
     build where selection stopped zooming, and the absolute floor beside it
     stops a tiny court satisfying the ratio while still being unreadable.
     MEASURED ON THE COMPLETING PICK, not on the first one. The camera now
     arrives in two steps (see the staged-zoom block below), so "is the picked
     title readable" is a question about where the zoom ENDS — asking it after
     the first click would pin half a zoom as the readable size and quietly
     re-open the bug this arm was written for. */
  const {vb1, vbRel, vb2, vb3, full} = await (async () => {
    /* THE ZOOM ARRIVES IN TWO PICKS — half the distance on the first, the rest
       on the next. The owner asked for exactly that: "instead of zooming all the
       way to the node at once ... rather zoom half as much so that i need to
       click it again to get the full zoom effect."
       FOUR MORE CLICKS FOR TWO PICKS, and the ones in between are the point. A
       re-click on a held claim RELEASES it — deliberate, owner-reported, and
       covered further down — so the gesture that completes the zoom is the next
       PICK of that node: click, put out, pick again. The release is measured
       too: dismissing a node is not a request to travel, and a camera that
       moved on it would be gliding toward something the reader just put away.
       AND A THIRD PICK MUST MOVE NOTHING, which is the arm that separates "the
       second pick completes it" from "every pick halves what is left". Under
       repeated halving both steps above still go inward, so neither would
       notice, and the camera would creep toward a reading size it never
       reaches — the Zeno case the tolerable-for-panning blend beside it can
       live with and a readability threshold cannot. */
    const vb1 = await camW();
    await clickNode(0);                        // releases the held claim
    await new Promise(r => setTimeout(r, 700));
    const vbRel = await camW();
    await clickNode(0);                        // ...and THIS pick completes the zoom
    await new Promise(r => setTimeout(r, 900));
    const vb2 = await camW(), full = await selTitleH();
    await clickNode(0);                        // out again
    await new Promise(r => setTimeout(r, 300));
    await clickNode(0);                        // a third pick: already all the way in
    await new Promise(r => setTimeout(r, 900));
    return {vb1, vbRel, vb2, vb3: await camW(), full};
  })();

  ok(`the first pick zooms in (viewBox ${vb0} -> ${vb1})`,
     vb0 > 0 && vb1 < vb0 * 0.999,
     "a viewBox that did not narrow is a camera that did not move");
  ok(`...but only partway — the next pick goes further in (${vb1} -> ${vb2})`,
     vb2 < vb1 * 0.99, "one click zoomed all the way in, which is what was asked away");
  {
    // HALF IN LOG UNITS, because that is the unit the wheel, the slider and
    // glideTo all work in. Bracketed rather than pinned: the fraction is exact
    // arithmetic on the camera, but zMax and the LOD floor can both clamp the
    // target, and the claim being made is "about half", not a specific decimal.
    const frac = Math.log(vb0 / vb1) / Math.log(vb0 / vb2);
    ok(`...and the first pick covered about half of the zoom (${frac.toFixed(2)} of it)`,
       frac > 0.3 && frac < 0.8, `vb ${vb0} -> ${vb1} -> ${vb2}`);
  }
  ok(`releasing a node does not travel (${vb1} -> ${vbRel})`,
     Math.abs(vbRel / vb1 - 1) < 0.002, "the camera moved on a click that put a node out");
  ok(`...and a third pick has nowhere left to go (${vb2} -> ${vb3})`,
     Math.abs(vb3 / vb2 - 1) < 0.002,
     "the zoom is still creeping inward, so it never arrives");
  {
    const ratio = full / before.titleH;
    ok(`the picked title is readable, not just bigger (${before.titleH}px -> ${full}px, ${ratio.toFixed(2)}x)`,
       ratio >= 1.6 && full >= 30,
       "the 1.35 spring alone would give " + (before.titleH * 1.35).toFixed(1) + "px");
  }
  /* A DEEP LINK ARRIVES ALL THE WAY IN, IN ONE MOVE. Staging the zoom is about
     the CLICK: a click is a step toward a node, and the reader can stop halfway.
     ?focus=<id> is a claim page's "map →" saying "this one" — the choice was
     made before the map existed, and landing that reader at half a zoom would
     make the link keep half its promise.
     ASSERTED AGAINST THE CLICK PATH'S OWN FINISHED ZOOM rather than a literal.
     Both are fit.w/tz for the same tz, so they must agree exactly — and a
     literal here would be a second copy of a number that moves with the
     fixture, passing on a map it no longer describes. This is also the only arm
     that says the two routes to a selected node end in the same place. */
  {
    const id0 = await page.evaluate(() => {
      const a = document.querySelector('.mnode-a[data-id]');
      return a ? a.getAttribute('data-id') : null;
    });
    await page.evaluate((s, i) => { location.hash = `/c/${s}/map?focus=${i}`; }, slug, id0);
    await new Promise(r => setTimeout(r, 1600));
    const vbF = await camW();
    ok(`?focus= lands at the finished zoom, not half of it (${vbF} vs ${vb2})`,
       vbF != null && Math.abs(vbF / vb2 - 1) < 0.002,
       `id=${id0} — half a zoom from this fixture's fit would be about ` +
       (Math.sqrt(vb0 * vb2)).toFixed(1));
  }
  ok("...quickly — under a quarter second",
     parseFloat(before.dur) > 0 && parseFloat(before.dur) <= 0.25, "dur=" + before.dur);
  // The curve's own numbers, so "overshoot" cannot be satisfied by a timing
  // fluke on a loaded machine: a cubic-bezier whose y2 exceeds 1 is the only
  // way the property can pass its target and come back.
  // cubic-bezier(x1,y1,x2,y2) — the overshoot is a CONTROL POINT above 1, and it
  // can be either y. In cubic-bezier(.34,1.56,.64,1) it is y1=1.56 and y2 is
  // exactly 1, so a check written against y2 alone reports no spring on the very
  // curve that has one. That was this assertion's first version.
  {
    const c = (before.ease.match(/cubic-bezier\(([^)]+)\)/) || [, ""])[1]
      .split(",").map(Number);
    ok("...because the easing curve itself passes 1",
       c.length === 4 && Math.max(c[1], c[3]) > 1, before.ease);
  }
  ok("the title grows with the box, not inside it",
     after.titleH > before.titleH, `${before.titleH} -> ${after.titleH}`);

  // ------------------------------------------------------------------- in place
  // transform-origin is reported in pixels. The node's own centre is half its
  // box; the MAP's centre would be hundreds of units away.
  ok("it scales about itself, not about the map (transform-box:fill-box)",
     before.transformBox === "fill-box", before.transformBox);
  {
    /* THE MIDDLE OF WHAT IT DRAWS, which is no longer the middle of the frame.
       A decided claim hangs its oval off the bottom-right corner, straddling the
       edge, and fill-box measures everything the anchor paints — so the origin
       sits MAPK.vov/2 below the frame's centre and the node rises by about a
       pixel and a half as it grows. That is the right pivot: the badge is part of
       the node and scales with it, and a pivot on the frame alone would swing the
       badge outward on selection, toward the neighbour.
       The vertical bound is loosened to that overhang and no further — the check
       is still that a node scales about ITSELF and not about the map, which is
       hundreds of units away, so a real regression is nowhere near this margin. */
    const [ox, oy] = before.origin.split(/\s+/).map(parseFloat);
    const slack = 2 + MAPKVOV / 2;
    ok(`...with the origin at the middle of what the node draws (${before.origin})`,
       Math.abs(ox - before.boxW / 2) < 2 && Math.abs(oy - before.boxH / 2) < slack,
       `box ${before.boxW}x${before.boxH} slack ${slack}`);
  }

  // -------------------------------------------------------------- every node
  // Overlap is a property of WHERE a node sits, so one node proves nothing.
  const sweep = [];
  /* ONE NODE AT A TIME, FROM A CLEAN MAP. Selection accumulates now — a second
     click adds a second node and a click on a held node RELEASES it — so a
     sweep that clicked all eleven in a row was measuring "does the eleventh
     click still select" against a map holding ten. Red since accumulate landed.
     Escape between clicks is the reset, dispatched at the map because its
     keydown listener is on the map box. */
  const clearMap = async () => {
    await page.evaluate(() => {
      const w = document.querySelector('.mapwrap');
      if (w) w.dispatchEvent(new KeyboardEvent("keydown", {key: "Escape", bubbles: true}));
    });
    await new Promise(r => setTimeout(r, 150));
  };
  for (let i = 0; i < n; i++) {
    await clearMap();
    await clickNode(i);
    await new Promise(r => setTimeout(r, 400));
    sweep.push(await page.evaluate(k => {
      const a = document.querySelectorAll('.mnode-a')[k];
      const r = a.getBoundingClientRect();
      const all = [...document.querySelectorAll('.mnode-a,.mfold-a,.mcourt-a')];
      const j = all.indexOf(a);
      const area = (x, y) => {
        const w = Math.min(x.right, y.right) - Math.max(x.left, y.left);
        const h = Math.min(x.bottom, y.bottom) - Math.max(x.top, y.top);
        return (w > 0 && h > 0) ? w * h : 0;
      };
      const mine = r.width * r.height;
      const later = all.slice(j + 1)
        .map(o => ({dim: o.classList.contains('dim'), a: area(r, o.getBoundingClientRect())}))
        .filter(o => o.a > 0);
      return {sel: a.classList.contains('selected'),
              lit: later.filter(o => !o.dim).length,
              worstPct: later.length ? Math.round(100 * Math.max(...later.map(o => o.a)) / mine) : 0};
    }, i));
  }
  ok(`every one of the ${n} nodes selects when clicked`, sweep.every(s => s.sel));
  /* OBSCURING OVERLAP, NOT ANY OVERLAP, and the distinction was forced by a
     measurement. The first version counted every later sibling whose box touched
     the grown one, and at 1.35x it failed with overlapped=1 — which sounded like
     the scale had gone too far. It had not: that one case was 3% of the node's
     area and the neighbour doing the clipping was DIMMED, which is the state the
     selection puts everything else into. A dimmed corner behind a lit node is
     the design working, not a collision.
     So the two facts are separated. A LIT later sibling over the selected node
     is unacceptable at any size — SVG has no z-index, so it genuinely covers.
     A dimmed one is tolerable but still bounded, because "dimmed" stops being an
     excuse somewhere: at 40% of the node the corner is gone whatever its
     opacity. Both numbers are printed, so growing the spring again shows its
     cost here instead of hiding it.
     HOW MUCH TEETH THIS HAS, measured rather than assumed: pushing the spring to
     2.0 leaves the worst overlap at 11% and the lit count at zero, so BOTH arms
     still pass. They do not bound the current size and are not the reason for
     it — they are a regression guard for a layout that packs nodes tighter than
     this docket's rings do. Said plainly here because the CSS comment beside the
     scale first claimed the opposite, and a check described as setting a limit
     it does not set is worse than no description. */
  ok("...and no LIT node drawn after it covers the selected one",
     sweep.every(s => s.lit === 0), "lit overlaps=" + sweep.filter(s => s.lit > 0).length);
  {
    const worst = Math.max(...sweep.map(s => s.worstPct));
    ok(`...with dimmed overlap staying incidental (worst ${worst}% of the node)`, worst <= 15,
       sweep.filter(s => s.worstPct > 0).map(s => s.worstPct + "%").join(" "));
  }

  // ------------------------------------------------- folders and the court too
  // THE REGRESSION THIS EXISTS FOR. The first version animated .mnode-a only.
  // Claim nodes all grew, this check passed, and the feature was reported as not
  // working — because the obvious thing to click on a map is a big labelled
  // FOLDER box, and those sat still. "A node" means any of the three kinds, so
  // the check has to walk all three or it certifies a third of the feature.
  for (const kind of [".mfold-a", ".mcourt-a"]) {
    await openMap();
    const cnt = await page.evaluate(k => document.querySelectorAll(k).length, kind);
    ok(`the map drew ${kind} to click`, cnt >= 1, "count=" + cnt);
    if (!cnt) continue;
    const w0 = await page.evaluate(k => {
      const a = document.querySelector(k);
      return {w: a.getBoundingClientRect().width, box: getComputedStyle(a).transformBox,
              dur: getComputedStyle(a).transitionDuration};
    }, kind);
    await page.evaluate(k => document.querySelector(k)
      .dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true})), kind);
    const mtx = (k) => page.evaluate(q => {
      const a = document.querySelector(q), m = getComputedStyle(a).transform;
      if (!m || m === "none") return 1;
      const n = m.match(/matrix\(([^)]+)\)/);
      return n ? parseFloat(n[1].split(",")[0]) : NaN;
    }, k);
    const wMid = await peakOf(() => mtx(kind));
    await new Promise(r => setTimeout(r, 900));
    const w1 = await page.evaluate(k =>
      document.querySelector(k).classList.contains('selected'), kind) ? await mtx(kind) : null;
    ok(`${kind}: clicking it selects it`, w1 !== null);
    if (w1 === null) continue;
    // Folders take the full 1.35 step, the court a smaller 1.18, so the floor
    // spans both while still failing a node that does not move at all.
    ok(`${kind}: scale is up (${w1})`, w1 > 1.12 && w1 < 1.45);
    ok(`${kind}: springs past its landing`, wMid > w1, `mid ${wMid}`);
    ok(`${kind}: scales about itself`, w0.box === "fill-box", w0.box);
  }
  await openMap();

  // --------------------------------------------------------- reduced motion
  // The SIZE is the feature and the spring is the delivery, so reduce takes the
  // spring only. Asserting the node still grows is the half that a blanket
  // `transition:none; transform:none` would quietly break.
  await page.emulateMediaFeatures([{name: 'prefers-reduced-motion', value: 'reduce'}]);
  await openMap();
  /* FROM A CLEAN MAP. openMap() re-goto()s a URL that differs from the current
     one only in its hash, which the browser treats as a same-document
     navigation — nothing reloads and the sweep's eleven selected nodes are all
     still held. This phase measured a node BEFORE clicking it and expected it to
     grow, so a node that was already selected made the ratio 1.00.
     IT PASSED BEFORE BECAUSE OF A BUG, which is the uncomfortable half: put()
     replaced the SVG without repainting, so any redraw silently dropped the
     selection and handed this phase the clean map it never asked for. Fixing
     that made the reliance visible. Escape is the real reset and now works. */
  await clearMap();
  const rm0 = await page.evaluate(() => {
    const a = document.querySelector('.mnode-a');
    return {w: a.getBoundingClientRect().width, dur: getComputedStyle(a).transitionDuration};
  });
  await clickNode(0);
  await new Promise(r => setTimeout(r, 400));
  const rm1 = await page.evaluate(() => {
    const a = document.querySelector('.mnode-a.selected');
    return a ? a.getBoundingClientRect().width : null;
  });
  ok("reduced motion turns the spring off", parseFloat(rm0.dur) === 0, "dur=" + rm0.dur);
  ok("...and still grows the node", rm1 !== null && rm1 / rm0.w > 1.10,
     rm1 ? `${rm0.w.toFixed(1)} -> ${rm1.toFixed(1)}` : "not selected");

  ok("no page errors throughout", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
