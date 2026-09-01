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
// WHAT IT DOES NOT COVER. Layout-dependent overlap. The sweep below asserts
// that no node drawn AFTER the selected one overlaps it, which is true of this
// docket's ring spacing at 1.18x — SVG has no z-index, so a grown node cannot
// paint above a later sibling, and reordering the DOM to fake it would scramble
// tab order. If the layout ever packs nodes tighter, this check is where it
// surfaces, as a count rather than as a screenshot somebody happens to look at.
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
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');

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
  await page.setViewport({width: 1440, height: 950});

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

  await openMap();
  const n = await page.evaluate(() => document.querySelectorAll('.mnode-a').length);
  ok("the map drew claim nodes to click", n >= 3, "nodes=" + n);

  // ------------------------------------------------------------ grows, and springs
  const before = await page.evaluate(() => {
    const a = document.querySelector('.mnode-a'), r = a.getBoundingClientRect();
    const cs = getComputedStyle(a), t = a.querySelector('text.mtitle');
    return {w: r.width, transformBox: cs.transformBox, origin: cs.transformOrigin,
            dur: cs.transitionDuration, ease: cs.transitionTimingFunction,
            titleH: t ? t.getBoundingClientRect().height : null,
            boxW: a.querySelector('.mnode').getBBox().width,
            boxH: a.querySelector('.mnode').getBBox().height};
  });
  await clickNode(0);
  // Mid-flight. A back-out curve is PAST its destination at this point; a plain
  // ease has not reached it. That difference is the whole "boing".
  await new Promise(r => setTimeout(r, 120));
  const mid = await page.evaluate(() =>
    (document.querySelector('.mnode-a.selected') || document.querySelector('.mnode-a'))
      .getBoundingClientRect().width);
  await new Promise(r => setTimeout(r, 700));
  const after = await page.evaluate(() => {
    const a = document.querySelector('.mnode-a.selected');
    if (!a) return null;
    const t = a.querySelector('text.mtitle');
    return {w: a.getBoundingClientRect().width,
            titleH: t ? t.getBoundingClientRect().height : null};
  });
  ok("clicking a node selects it on the map, without leaving for its page", !!after);
  if (!after) { await browser.close(); process.exit(1); }

  const grew = after.w / before.w;
  ok(`the selected node is bigger (${grew.toFixed(3)}x)`, grew > 1.10 && grew < 1.30,
     `${before.w.toFixed(1)} -> ${after.w.toFixed(1)}`);
  ok(`...and the motion overshoots its landing (mid ${mid.toFixed(1)} > settled ${after.w.toFixed(1)})`,
     mid > after.w);
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
    const [ox, oy] = before.origin.split(/\s+/).map(parseFloat);
    ok(`...with the origin at the node's own middle (${before.origin})`,
       Math.abs(ox - before.boxW / 2) < 2 && Math.abs(oy - before.boxH / 2) < 2,
       `box ${before.boxW}x${before.boxH}`);
  }

  // -------------------------------------------------------------- every node
  // Overlap is a property of WHERE a node sits, so one node proves nothing.
  const sweep = [];
  for (let i = 0; i < n; i++) {
    await clickNode(i);
    await new Promise(r => setTimeout(r, 400));
    sweep.push(await page.evaluate(k => {
      const a = document.querySelectorAll('.mnode-a')[k];
      const r = a.getBoundingClientRect();
      const all = [...document.querySelectorAll('.mnode-a,.mfold-a,.mcourt-a')];
      const j = all.indexOf(a);
      const hit = (x, y) => !(y.right < x.left || y.left > x.right || y.bottom < x.top || y.top > x.bottom);
      return {sel: a.classList.contains('selected'),
              later: all.slice(j + 1).filter(o => hit(r, o.getBoundingClientRect())).length};
    }, i));
  }
  ok(`every one of the ${n} nodes selects when clicked`, sweep.every(s => s.sel));
  ok("...and none is overlapped by a node drawn after it",
     sweep.every(s => s.later === 0),
     "overlapped=" + sweep.filter(s => s.later > 0).length);

  // --------------------------------------------------------- reduced motion
  // The SIZE is the feature and the spring is the delivery, so reduce takes the
  // spring only. Asserting the node still grows is the half that a blanket
  // `transition:none; transform:none` would quietly break.
  await page.emulateMediaFeatures([{name: 'prefers-reduced-motion', value: 'reduce'}]);
  await openMap();
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
