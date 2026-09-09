// ON A PHONE THE MAP IS THE PAGE, and it was a sliver.
//
// REPORTED: "on the mobile phone the map should appear much larger... its
// height is a sliver". MEASURED at 390x844 before the fix: the svg was 176px
// tall, a fifth of the screen, with the card taking 80 of the 270 the holder had
// been given.
//
// WHY IT COLLAPSED, because the fix only makes sense against the cause. .maphold
// is a grid that takes its height from `flex:1` on a parent that fills the
// viewport. That works while the two columns sit side by side; below 860 the
// grid becomes ONE column, so the map and the card become two ROWS dividing
// whatever the holder resolved to — and on a narrow screen that was 270px.
//
// TWO THINGS THIS GUARDS, and they pull against each other, which is the whole
// reason it is worth a test:
//
//	the map must be LARGE — a definite share of the viewport, not a share of
//	  whatever is left over
//	the card must still be READABLE when a node is tapped — the first attempt
//	  took the map to 62vh and left the card 26px tall holding 184 characters,
//	  because a taller map came straight out of the card's row
//
// A test that checked only the first would have passed that broken state.
const {PAGE, demoPage} = require('./harness');

// Real phone viewports, plus the two sides of the breakpoint so the desktop
// layout is known not to have moved.
const SIZES = [
  [390, 844, "iPhone 14"],
  [360, 780, "small Android"],
  [430, 932, "iPhone Pro Max"],
  [768, 1024, "iPad portrait"],
  [1440, 900, "desktop"],
];

(async () => {
  const {browser, page, errs} = await demoPage({width: 390, height: 844});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  for (const [w, h, label] of SIZES) {
    await page.setViewport({width: w, height: h});
    await page.goto(PAGE + '#/', {waitUntil: 'networkidle0'});
    await page.goto(PAGE + '#/c/orem/map', {waitUntil: 'networkidle0'});
    await new Promise(z => setTimeout(z, 1300));

    const r = await page.evaluate(async () => {
      const svg = document.querySelector("svg.mapsvg");
      const node = document.querySelector("a.mnode-a");
      if (!svg || !node) return {err: "no map drawn"};
      const before = Math.round(svg.getBoundingClientRect().height);
      // Tap a node, which is what makes the card compete for room.
      node.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true}));
      await new Promise(z => setTimeout(z, 600));
      const sel = document.getElementById("mapsel");
      const doc = document.documentElement;
      return {
        map: Math.round(svg.getBoundingClientRect().height),
        mapBefore: before,
        card: Math.round(sel.getBoundingClientRect().height),
        chars: (sel.textContent || "").trim().length,
        // scrollHeight past clientHeight is the squashed-card signature
        cardClipped: sel.scrollHeight > sel.clientHeight + 2,
        hscroll: doc.scrollWidth > doc.clientWidth + 1,
        vh: window.innerHeight,
      };
    });
    if (r.err) { ok(`${label}: the map draws`, false, r.err); continue; }

    const pct = Math.round(100 * r.map / r.vh);
    /* HALF THE VIEWPORT IS THE FLOOR. The reported state was 21%; the fix gives
       62% on every phone size. Fifty is chosen as the line because below it the
       map has stopped being the thing you came to the page for. */
    ok(`${label} (${w}x${h}): the map is at least half the viewport (${pct}%)`,
       pct >= 50, JSON.stringify(r));

    /* AND THE CARD SURVIVES IT. 120px is roughly four lines plus the button —
       enough to read a claim and reach "Open claim page". The 26px state that
       the first attempt produced fails this while passing the check above. */
    ok(`${label}: ...and the tapped node's card is still readable (${r.card}px for ${r.chars} chars)`,
       r.card >= 120 && !r.cardClipped, JSON.stringify(r));

    ok(`${label}: ...and nothing scrolls sideways`, r.hscroll === false, JSON.stringify(r));

    // Selecting must not resize the map — the desktop layout reserves the card's
    // column for exactly this reason, and the mobile rows must not undo it.
    ok(`${label}: ...and tapping a node does not resize the map`,
       r.map === r.mapBefore, JSON.stringify({before: r.mapBefore, after: r.map}));
  }

  /* ---- ZOOM, WHICH IS THE THING A MAP IS FOR --------------------------------
     Reported as "I can't zoom on the map view in mobile". Everything above this
     line passed throughout: the arms here were about LAYOUT, and a map you
     cannot zoom is the right size and still useless.
     THE CAUSE WAS ONE LINE OF CSS MEETING ONE MISSING HANDLER. .mapwrap svg
     carries touch-action:none — the browser runs no gesture of its own — and
     the only zoom in the page was the wheel. A phone has no wheel.
     AND IT WAS WORSE THAN INERT: the first of two fingers drove the
     single-finger drag, so a pinch PANNED. Measured before the fix, a spread
     took the viewBox from `422.15 368.22 339.69 251.56` to
     `357.54 368.22 339.69 251.56` — x moved, width and height did not.
     SO EVERY ARM HERE READS WIDTH, NOT THE VIEWBOX STRING. The first version of
     that measurement compared whole strings and reported the pan as a
     successful zoom; only width and height are zoom, and x and y are pan. */
  const gesture = kind => page.evaluate(k => {
    const svg = document.querySelector('.mapwrap svg');
    if (!svg) return false;
    const b = svg.getBoundingClientRect();
    const cx = b.left + b.width / 2, cy = b.top + b.height / 2;
    const send = (t, id, x, y) => svg.dispatchEvent(new PointerEvent(t, {
      pointerId: id, pointerType: 'touch', isPrimary: id === 1, bubbles: true,
      cancelable: true, clientX: x, clientY: y, buttons: t === 'pointerup' ? 0 : 1,
      view: window}));
    if (k === 'spread') {
      send('pointerdown', 1, cx - 30, cy); send('pointerdown', 2, cx + 30, cy);
      for (let d = 30; d <= 100; d += 10) { send('pointermove', 1, cx - d, cy); send('pointermove', 2, cx + d, cy); }
      send('pointerup', 1, cx - 100, cy); send('pointerup', 2, cx + 100, cy);
    } else if (k === 'squeeze') {
      send('pointerdown', 1, cx - 100, cy); send('pointerdown', 2, cx + 100, cy);
      for (let d = 100; d >= 30; d -= 10) { send('pointermove', 1, cx - d, cy); send('pointermove', 2, cx + d, cy); }
      send('pointerup', 1, cx - 30, cy); send('pointerup', 2, cx + 30, cy);
    } else {
      send('pointerdown', 1, cx, cy);
      for (let n = 1; n <= 8; n++) send('pointermove', 1, cx - n * 10, cy);
      send('pointerup', 1, cx - 80, cy);
    }
    return true;
  }, kind);
  const viewBox = () => page.evaluate(() => {
    const svg = document.querySelector('.mapwrap svg');
    return svg ? svg.getAttribute('viewBox').split(' ').map(Number) : null;
  });
  const afterGesture = async kind => {
    await page.setViewport({width: 390, height: 844});
    await page.goto(PAGE + '#/', {waitUntil: 'networkidle0'});
    await page.goto(PAGE + '#/c/orem/map', {waitUntil: 'networkidle0'});
    await new Promise(z => setTimeout(z, 1300));
    const a = await viewBox();
    if (!a) return null;
    await gesture(kind);
    await new Promise(z => setTimeout(z, 400));
    const b = await viewBox();
    return {w0: +a[2].toFixed(1), w1: +b[2].toFixed(1), x0: +a[0].toFixed(1), x1: +b[0].toFixed(1)};
  };

  /* AND THE CONTROLS ARE REACHABLE WITH A THUMB. They were never the reason the
     map could not be zoomed — all three are on screen at 390px and all three
     work — but the slider measured 140x16, and 16px is not a target. 24 is the
     figure this file holds itself to elsewhere (SC 2.5.8); the buttons already
     passed it at 26x33 and are asserted here so a later restyle cannot quietly
     shrink them either. */
  await page.setViewport({width: 390, height: 844});
  await page.goto(PAGE + '#/', {waitUntil: 'networkidle0'});
  await page.goto(PAGE + '#/c/orem/map', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1300));
  const targets = await page.evaluate(() => {
    const out = {};
    for (const id of ['mz-out', 'mz-in', 'mz-slider']) {
      const e = document.getElementById(id);
      const r = e && e.getBoundingClientRect();
      out[id] = r ? {w: Math.round(r.width), h: Math.round(r.height)} : null;
    }
    return out;
  });
  for (const id of ['mz-out', 'mz-in', 'mz-slider']) {
    const t = targets[id];
    ok(`the ${id} control is at least 24px tall (${t ? t.h : "absent"}px)`,
       !!t && t.h >= 24 && t.w >= 24, JSON.stringify(targets));
  }

  const spread = await afterGesture('spread');
  ok(`two fingers spreading zoom the map IN (${spread && spread.w0} -> ${spread && spread.w1})`,
     !!spread && spread.w1 < spread.w0 * 0.9, JSON.stringify(spread));
  const squeeze = await afterGesture('squeeze');
  ok(`...and squeezing zooms it OUT (${squeeze && squeeze.w0} -> ${squeeze && squeeze.w1})`,
     !!squeeze && squeeze.w1 > squeeze.w0 * 1.1, JSON.stringify(squeeze));
  /* ONE FINGER STILL ONLY PANS, which is the regression the pinch code could
     cause: the two gestures share pointerdown, pointermove and pointerup, and
     a move that both zooms and pans is unusable. */
  const drag = await afterGesture('drag');
  ok("one finger pans and does not zoom",
     !!drag && drag.w0 === drag.w1 && drag.x0 !== drag.x1, JSON.stringify(drag));

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
