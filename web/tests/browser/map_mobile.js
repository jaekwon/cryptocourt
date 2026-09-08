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

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
