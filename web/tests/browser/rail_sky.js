// The rail is the night sky, and Leo is up by the throne.
//
// WHY THIS EXISTS. The sidebar's ground moved from the chat panel to the whole
// rail, and every fact that makes that work is invisible in the source:
//
//   1. .rail must re-resolve --ink for its own subtree. Overriding the token is
//      NOT enough — what inherits into the rail is body's COMPUTED rgb, resolved
//      against :root long before it arrives. Without `color:var(--ink)` on the
//      rail, .brand .mark stayed #16202a on the light theme: near-black text on
//      a near-black sky. Nothing in the source looks wrong; the sidebar is just
//      blank where a name should be.
//   2. The rail's chat slot wears .railchat AND .chatpanel ON ONE ELEMENT, so
//      `.railchat .chatpanel` — the descendant form, which is what anyone writes
//      first — matches nothing. It matched nothing here, and the panel kept
//      painting its own sky: a second gradient with its own top stop halfway
//      down the column, and a second Leo, since the plate carries the
//      constellation. The render looked finished.
//   3. Leo has to land near the throne. The plate is real sky at one
//      right-ascension window, so the constellation sits at a fixed 44% of the
//      plate's height and is placed by a -169px offset that depends on the rail's
//      width. Change the rail's width and Leo slides off the brand block.
//   4. The starfield has to stop before the plate's own bottom edge does, or the
//      edge reads as a seam across the sidebar. The scrim over it is opaque from
//      300px; the plate ends between 296px and 370px across rail widths.
//
// HOW 4 IS MEASURED. Not by reading CSS — by turning the RAIL's plate layer off
// and comparing screenshot bytes strip by strip. A strip whose bytes change is a
// strip with stars in it. That is what settled where the field actually ends,
// after a downscaled screenshot suggested stars near the foot that were really
// the demo dot and some punctuation.
//
// AND WHAT THAT MEASUREMENT CANNOT SEE, which an ablation had to teach it: the
// override it injects names `.rail`, so a sky painted by the PANEL survives in
// both shots and the strips come out identical. The strip diff is blind to case
// 2 by construction — reverting the reset to `.railchat .chatpanel` leaves every
// strip unchanged and only the slot-background arm above fires. Two arms for two
// facts, and the header used to claim the wrong one caught it.
//
// Ablated, and each fires on the arm named: dropping `color:var(--ink)` from
// .rail fails both light-theme arms (rail color rgb(22,32,42), worst contrast
// 1.08:1); writing the chat reset as `.railchat .chatpanel` fails the slot arm
// alone, for the reason just given; moving the plate offset back to the chat
// panel's -34px fails the Leo arm (figure at y 151..259, well below the throne's
// 22..54); pushing the scrim's opaque stop to 700px fails the no-seam arm with
// stars at every strip down to 870.
const {PAGE, demoPage} = require('./harness');
const crypto = require('crypto');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1440, height: 900});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // ---------------------------------------------------------------- the ink
  // Both themes, because this is the arm that only fails on one of them: the
  // dark theme's own tokens already read on a night sky, so a rail that forgot
  // to re-resolve them looks perfect until somebody opens the site in daylight.
  for (const scheme of ['light', 'dark']) {
    await page.emulateMediaFeatures([{name: 'prefers-color-scheme', value: scheme}]);
    await page.goto(PAGE + '#/c/orem/4', {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 1500));
    const m = await page.evaluate(() => {
      const rail = document.querySelector('.rail');
      if (!rail) return {err: 'no .rail'};
      const rgb = t => { const n = String(t).match(/[\d.]+/g) || []; return n.slice(0, 3).map(Number); };
      const lum = c => { const f = c.map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
        return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]; };
      const ratio = (a, b) => { const x = lum(rgb(a)), y = lum(rgb(b));
        const [h, l] = x > y ? [x, y] : [y, x]; return +((h + 0.05) / (l + 0.05)).toFixed(2); };
      // The sky the text sits on, sampled where the text is: the rail's own
      // colour at the top, its gradient's end at the foot.
      const sky = ['rgb(10,10,20)', 'rgb(24,19,51)'];
      const pick = sel => { const e = rail.querySelector(sel); return e ? getComputedStyle(e).color : null; };
      const parts = {mark: '.brand .mark', word: '.brand h1', tag: '.brand .tag',
                     nav: '.nav a', sec: '.nav .sec', sel: '.node select'};
      const out = {railColor: getComputedStyle(rail).color, inks: {}, worst: {}};
      for (const [k, sel] of Object.entries(parts)) {
        const c = pick(sel);
        out.inks[k] = c;
        if (c) out.worst[k] = Math.min(ratio(c, sky[0]), ratio(c, sky[1]));
      }
      return out;
    });
    ok(`${scheme}: the rail re-resolves its own ink`, !m.err && m.railColor === 'rgb(236, 233, 247)',
       m.err || `rail color=${m.railColor}`);
    // 4.5 is AA for body text; the wordmark is 22px/600, which AA counts as
    // large at 3.0 — it clears the body floor anyway, so one number covers all.
    const low = Object.entries(m.worst || {}).filter(([, v]) => !(v >= 4.5));
    ok(`${scheme}: every label in the rail reads on the sky (worst ${Math.min(...Object.values(m.worst || {0: 0})).toFixed?.(2) || '?'}:1)`,
       low.length === 0, low.map(([k, v]) => `${k}=${v}`).join(" ") + "  " + JSON.stringify(m.inks));
  }
  await page.emulateMediaFeatures([{name: 'prefers-color-scheme', value: 'light'}]);

  // ------------------------------------------------- one sky, and where it ends
  const geo = await page.evaluate(() => {
    const rail = document.querySelector('.rail');
    const slot = rail.querySelector('.chatpanel');
    const seat = rail.querySelector('.brand .seat').getBoundingClientRect();
    const cs = getComputedStyle(rail);
    return {
      railW: Math.round(rail.getBoundingClientRect().width),
      plateOnRail: /base64/.test(cs.backgroundImage),
      // the scrim is the FIRST layer, because the first background-image paints
      // on top and it has to be over the plate to fade it
      scrimFirst: /^linear-gradient/.test(cs.backgroundImage.trim()),
      pos: cs.backgroundPosition,
      slotBg: slot ? getComputedStyle(slot).backgroundImage : null,
      throne: {top: Math.round(seat.top), bottom: Math.round(seat.bottom)},
    };
  });
  ok("the rail carries the plate", geo.plateOnRail === true);
  ok("...with the scrim over it, not under", geo.scrimFirst === true, geo.pos);
  ok("the rail's chat slot paints no sky of its own",
     geo.slotBg === 'none', `slot background-image=${String(geo.slotBg).slice(0, 40)}`);

  const strip = async y => {
    const buf = await page.screenshot({clip: {x: 0, y, width: geo.railW, height: 18}});
    return crypto.createHash('sha1').update(buf).digest('hex');
  };
  const YS = [40, 120, 200, 280, 320, 400, 520, 660, 800, 870];
  const before = {};
  for (const y of YS) before[y] = await strip(y);
  await page.evaluate(() => {
    const st = document.createElement('style');
    st.id = 'noplate';
    st.textContent = ".rail{background-image:linear-gradient(to bottom, rgba(10,10,20,0) 0,"
      + " rgba(10,10,20,0) 150px, #130f26 300px, #181333 100%) !important}";
    document.head.appendChild(st);
  });
  await new Promise(r => setTimeout(r, 400));
  const starry = [];
  for (const y of YS) if (before[y] !== await strip(y)) starry.push(y);
  await page.evaluate(() => document.getElementById('noplate').remove());

  ok("there are stars at the top of the rail, by the brand",
     starry.includes(40) && starry.includes(120), `starry at ${starry.join(",")}`);
  // The plate's own bottom edge lands between 296px and 370px across rail
  // widths; the scrim must have closed before then, or it shows as a rule.
  ok("...and none below the fade, so the plate's edge is never a seam",
     !starry.some(y => y >= 320), `starry at ${starry.join(",")}`);

  // ------------------------------------------------------- Leo, near the throne
  // The constellation occupies 34.3%..54.4% of the plate, which is real sky and
  // not adjustable. At the rail's width that is a 108px figure; it has to sit
  // against the brand block, and WHOLE — a negative top would clip the Sickle.
  const leo = await page.evaluate(() => {
    const rail = document.querySelector('.rail');
    const cs = getComputedStyle(rail);
    const dy = parseFloat((cs.backgroundPosition.split(",")[1] || "").trim().split(/\s+/)[1]);
    const w = rail.getBoundingClientRect().width;
    const h = w * 1190 / 640;                 // the plate's own aspect
    return {top: dy + 0.343 * h, bottom: dy + 0.544 * h, dy, plateH: h};
  });
  ok("Leo's figure sits against the brand block, whole",
     leo.top >= 0 && leo.top < geo.throne.bottom + 60 && leo.bottom > geo.throne.bottom,
     `figure y ${leo.top.toFixed(0)}..${leo.bottom.toFixed(0)}, throne ${geo.throne.top}..${geo.throne.bottom}`);

  ok("no page errors with the sky behind the rail", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
