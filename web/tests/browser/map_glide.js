// The camera moves ONCE, and that is a claim about its speed.
//
// WHY THIS EXISTS. "Blend sort of works but you're testing my reaction speed. I
// can see that it does two movements, it isn't continuous." Every obvious
// explanation for that was wrong: there is exactly one glideTo call site and one
// centreOn call site, the tween cancels any predecessor, and instrumenting
// SVGElement.setAttribute on the live map showed a single unbroken run of
// viewBox writes per click — 13 frames, 218ms, no gap anywhere in it.
//
// THE SEAM WAS IN THE VELOCITY, NOT IN THE FRAMES. The curve was `1-(1-k)^3`,
// which leaves at three times its average speed and arrives at zero. Measured
// on that run, the pan moved 72 world units in its first frame and 1 in its
// last. A reader does not see one glide with an unusual profile; they see a
// lurch and then a slow creep chasing it, which is exactly "two movements".
//
// SO WHAT IS ASSERTED IS THE SHAPE OF THE MOTION: no frame may be wildly faster
// than the average, and the fastest frame must not be the first. Smoothstep
// satisfies both — motionless at both ends, one and a half times average in the
// middle. Ease-out cubic fails both, which is what makes these arms worth
// running rather than a restatement of the code.
//
// MEASURED BY BREAKING IT, each against a tree that was otherwise clean. The
// clean run reads 1.49x peak-over-average, against 1.5 predicted by the curve:
//   restoring 1-(1-k)^3   all three profile arms fail — 2.95x, leaving AT the
//                         peak, and that peak 3% of the way in
//   ease-in (k*k*k)       speed (2.57x) and middle (90% through) fail; the
//                         gentle-start arm PASSES, which is why it is not enough
//                         on its own and why the middle arm is not a duplicate
//   linear (e = k)        ONLY the gentle-start arm fails — a constant speed is
//                         1.01x its own average and its "peak" is the first
//                         interval. That arm is the only one that can see it,
//                         which is what earns it its place
//   MS back to a flat 220 only the duration arm fails (217ms), and only because
//                         the flight was chosen to be the longest available
//
// A NOTE ON WHY THIS IS A BROWSER CHECK AND NOT A SOURCE ONE. mapclick_test.js
// runs the same glide under a synchronous requestAnimationFrame stub, where the
// wall clock barely advances and the whole flight completes in 120 nested calls
// at k~0. It can prove the camera is stepped and where it lands; it cannot see a
// velocity profile, because under that host there isn't one. This needs real
// frames on a real clock.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1440, height: 950});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  /* THE LOG IS INSTALLED ON THE PROTOTYPE, not on the svg element. put() replaces
     box.innerHTML outright, so every redraw hands back a NEW svg and a patch on
     the instance stops recording without saying so — the first version of this
     measurement reported "0 viewBox writes" for a click that plainly moved the
     camera. The prototype survives every redraw. */
  await page.evaluateOnNewDocument(() => {
    window.__vb = [];
    const proto = SVGElement.prototype, orig = proto.setAttribute;
    proto.setAttribute = function (k, v) {
      if (k === "viewBox" && this.tagName === "svg")
        window.__vb.push([performance.now(), String(v)]);
      return orig.call(this, k, v);
    };
  });

  const slug = await (async () => {
    await page.goto(PAGE + '#/', {waitUntil: 'networkidle2'});
    await new Promise(r => setTimeout(r, 800));
    return page.evaluate(() => [...document.querySelectorAll('a[href^="#/c/"]')]
      .map(x => x.getAttribute('href'))
      .map(h => (h.match(/^#\/c\/([a-z0-9-]+)$/) || [])[1]).find(Boolean) || null);
  })();
  ok("the directory offers a court to open", !!slug, slug || "none");
  if (!slug) { await browser.close(); process.exit(1); }

  await page.goto(PAGE + '#/c/' + slug + '/map', {waitUntil: 'networkidle2'});
  for (let i = 0; i < 20; i++) {
    if (await page.evaluate(() => !!document.querySelector('.mnode-a'))) break;
    await new Promise(r => setTimeout(r, 400));
  }
  await new Promise(r => setTimeout(r, 2200));

  /* THE FURTHEST NODE FROM WHERE THE CAMERA IS, because a glide that barely
     travels has no profile to measure: every frame of it rounds to the same
     view and both arms below would pass on any curve at all.
     FURTHEST AMONG THE ONES THAT CAN ACTUALLY BE CLICKED. The sample court is
     eleven nodes in a ring, each 287px wide, and at the default fit several of
     their CENTRES fall outside the svg's own box — one of them at y=-49. The
     first version of this check picked the furthest of all of them and clicked
     into the page chrome above the map, which recorded nothing and read as "the
     camera did not move". So the centre has to be inside the box, with a margin
     wide enough that the point belongs to the node rather than to its edge. */
  const flight = async () => {
    await page.evaluate(() => { window.__vb.length = 0; });
    const t = await page.evaluate(() => {
      const svg = document.querySelector('.mapwrap svg') || document.querySelector('svg');
      const vb = (svg.getAttribute("viewBox") || "0 0 1 1").split(" ").map(Number);
      const [ax, ay] = [vb[0] + vb[2] / 2, vb[1] + vb[3] / 2];
      const box = svg.getBoundingClientRect();
      const M = 8;
      let best = null, far = -1;
      for (const a of document.querySelectorAll('.mnode-a')) {
        const r = a.getBoundingClientRect();
        if (!r.width) continue;
        const px = r.x + r.width / 2, py = r.y + r.height / 2;
        if (px < box.left + M || px > box.right - M
         || py < box.top + M || py > box.bottom - M) continue;
        // client px -> world units, so "furthest" is measured in the camera's
        // own frame rather than on the screen.
        const wx = vb[0] + (px - box.x) / box.width * vb[2];
        const wy = vb[1] + (py - box.y) / box.height * vb[3];
        const d = Math.hypot(wx - ax, wy - ay);
        if (d > far) { far = d; best = {sx: Math.round(px), sy: Math.round(py), id: a.dataset.id || a.dataset.fid}; }
      }
      return best && Object.assign(best, {travel: +far.toFixed(1), viewport: vb[2]});
    });
    if (!t) return null;
    await page.mouse.click(t.sx, t.sy);
    await new Promise(r => setTimeout(r, 1600));
    /* THE CLICK HAS TO HAVE LANDED. Without this, a point that misses the node
       gives an empty frame log, and an empty frame log is indistinguishable from
       a camera that refused to move — which is the wrong bug to go looking for. */
    const took = await page.evaluate(() => !!document.querySelector('.mnode-a.selected'));
    if (!took) return {node: t.id, missed: true, frames: 0};
    const raw = await page.evaluate(() => window.__vb.slice());
    /* VELOCITY, NOT TRAVEL PER FRAME. The first version of this measurement
       divided nothing by time, and under the full browser-check runner — several
       Chromes in sequence, a loaded machine — a dropped early frame covered
       three frames' distance in one interval and was reported as the peak, 7% of
       the way in. That is a scheduling artifact, not a velocity: the curve
       controls units per millisecond and says nothing about when rAF fires. So
       each interval is divided by its own elapsed time, and the average is the
       whole flight's travel over the whole flight's duration, which makes the
       ratio below the same number the easing arithmetic predicts.
       INTERVALS UNDER 4ms ARE DROPPED. Two writes in the same frame — a glide
       step landing beside a schedule() — divide a real distance by noise. */
    const mid = v => { const a = v.split(" ").map(Number); return [a[0] + a[2] / 2, a[1] + a[3] / 2, a[2]]; };
    const span = raw.length > 1 ? raw[raw.length - 1][0] - raw[0][0] : 0;
    const vel = [];          // {v: units/ms, at: 0..1 through the flight}
    let total = 0, gap = 0;
    for (let i = 1; i < raw.length; i++) {
      const [x0, y0] = mid(raw[i - 1][1]), [x1, y1] = mid(raw[i][1]);
      const d = Math.hypot(x1 - x0, y1 - y0), dt = raw[i][0] - raw[i - 1][0];
      total += d;
      if (dt > gap) gap = dt;
      if (dt >= 4 && span > 0)
        vel.push({v: d / dt, at: ((raw[i][0] + raw[i - 1][0]) / 2 - raw[0][0]) / span});
    }
    return {
      node: t.id, travel: t.travel, viewport: t.viewport, vel, gap,
      frames: raw.length, total,
      ms: Math.round(span),
      avg: span > 0 ? total / span : 0,
    };
  };

  const f = await flight();
  ok("a click on a distant node moves the camera", !!(f && f.frames > 3),
     f && f.missed ? `the click on node ${f.node} did not select it`
                   : JSON.stringify(f && {frames: f.frames, travel: f.travel}));
  if (!f || f.frames <= 3) { await browser.close(); process.exit(1); }
  console.log(`   (node ${f.node}: ${f.travel} units across a ${Math.round(f.viewport)}-unit `
    + `viewport, ${f.frames} frames in ${f.ms}ms)`);

  /* STILL ONE TWEEN. This is the arm that would catch a genuine second glide —
     a repaint or a late fill calling centreOn again after the first settles —
     and it is cheap to keep beside the profile arms it does not duplicate. */
  ok(`the frames are one unbroken run (longest gap ${Math.round(f.gap)}ms)`,
     f.gap < 60, "a gap that long is a second movement, not a slow frame");

  const fast = f.vel.reduce((a, b) => b.v > a.v ? b : a, f.vel[0]);
  /* 2.2x IS THE BOUND, AND IT SITS BETWEEN TWO PIECES OF ARITHMETIC. Peak speed
     over average speed is a property of the curve alone: smoothstep's is exactly
     1.5, and both an ease-out and an ease-in cubic's is exactly 3. Measuring
     velocity rather than per-frame travel is what makes those numbers show up
     here instead of whatever the frame scheduler did. */
  ok(`nothing outruns the average speed (peak ${fast.v.toFixed(2)} vs average `
     + `${f.avg.toFixed(2)} units/ms = ${(fast.v / f.avg).toFixed(2)}x)`,
     fast.v / f.avg < 2.2,
     "a burst several times the average is the lurch the reader sees");
  /* AND THE LURCH IS AT THE FRONT WHEN IT HAPPENS, so this says specifically
     that the motion does not leave at full speed. It is a different assertion
     from the one above — an ease-in fails the bound and passes this. */
  ok(`the motion starts gently (${f.vel[0].v.toFixed(2)} of a `
     + `${fast.v.toFixed(2)} peak)`, f.vel[0].v < fast.v * 0.85,
     "leaving at top speed reads as a jump that the rest of the glide follows");
  /* THE FASTEST MOMENT IS IN THE MIDDLE, which is the positive form of the same
     property and the thing that makes a sweep readable: the eye is given the
     travel where it is looking, not at the ends where it looks for a seam.
     BY TIME, NOT BY FRAME INDEX — under load the frames are not evenly spaced,
     and "frame 1 of 15" was 7% of the way through the flight on one run and
     rather more on another. */
  ok(`...and the fastest moment is in the middle (${(fast.at * 100).toFixed(0)}% through)`,
     fast.at > 0.15 && fast.at < 0.85, `${f.vel.length} intervals measured`);
  /* LONG ENOUGH TO FOLLOW. "You're testing my reaction speed" was the other half
     of the report, and a fixed 220ms is what a glide across the graph had. The
     duration follows the distance now, so this is asserted on a flight that was
     chosen to be the longest available. Bounded above too: a camera that takes
     most of a second to cross the map is no longer explaining anything. */
  ok(`a long glide lasts long enough to read (${f.ms}ms)`, f.ms >= 260 && f.ms <= 800,
     "the duration should follow the distance, and this was the furthest node");

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
