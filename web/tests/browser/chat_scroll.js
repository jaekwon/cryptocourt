// THE CHAT OPENS AT THE NEWEST MESSAGE, which it sometimes did not.
//
// Reported as "sometimes the chat doesn't scroll down to the latest message upon
// loading". Sometimes is the whole diagnosis: paintLog only scrolled when it
// judged the reader to be at the foot already, and it judged that from
// scrollHeight and clientHeight — which are BOTH ZERO if the first transcript
// arrives before the panel has been laid out. `0 - 0 - 0 < 24` is true, so it
// set scrollTop to a scrollHeight of 0, and once layout happened the reader was
// looking at the top of the thread with nothing left to retry the scroll.
//
// WHY A BROWSER, AND WHY THIS SHAPE. The bug is entirely about the order of
// layout and paint, so it cannot be reproduced without a layout engine, and it
// cannot be reproduced by simply loading the page either — on a fast local load
// the panel is usually laid out in time, which is exactly why the report said
// "sometimes". So the condition is forced: the log is given no height, the
// transcript is painted into it, and only then is the height restored. That is
// the same sequence as a slow first paint, made deterministic.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 900});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1200));

  const log = await page.evaluate(() => {
    const el = document.querySelector(".chatlog");
    if (!el) return null;
    return {rows: el.children.length,
            scrollable: el.scrollHeight > el.clientHeight + 4,
            atBottom: el.scrollHeight - el.scrollTop - el.clientHeight < 24};
  });
  ok("the demo court renders a chat log", log && log.rows > 0, JSON.stringify(log));
  if (!log) { console.log("\n1 FAILURES"); await browser.close(); process.exit(1); }

  // On an ordinary load it should already be at the foot. If the sample thread
  // is shorter than the panel there is nothing to scroll, and that is reported
  // rather than passed silently — a check that cannot fail is not a check.
  if (log.scrollable) {
    ok("an ordinary load opens at the newest message", log.atBottom === true,
       JSON.stringify(log));
  } else {
    ok("...the sample thread does not overflow the panel, so nothing to scroll",
       true, "SKIPPED the ordinary-load arm: nothing overflows");
  }

  /* THE FORCED CASE, which is the bug — and it has to go through the panel's own
     paint, not around it.
     THE FIRST VERSION OF THIS TEST WROTE innerHTML ITSELF and then set scrollTop
     to 0, which fires a scroll event, which correctly told the panel the reader
     had moved away from the foot. So it measured its own interference and failed
     against code that was right. What follows collapses the log with a
     STYLESHEET installed before the page loads, so the mount and the first paint
     genuinely happen with no height, and then removes it. That is the real
     sequence: content before layout. */
  await page.evaluateOnNewDocument(() => {
    const st = document.createElement("style");
    st.id = "flatten-log";
    // !important, because the panel's own rule is what would otherwise win.
    // padding too, or clientHeight keeps a few pixels and the log is not flat.
    st.textContent = ".chatlog{height:0 !important; min-height:0 !important;"
      + "padding:0 !important; border:0 !important}";
    document.addEventListener("DOMContentLoaded", () => document.head.appendChild(st));
  });
  await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1200));

  const flat = await page.evaluate(() => {
    const el = document.querySelector(".chatlog");
    return {clientHeight: el.clientHeight, scrollHeight: el.scrollHeight};
  });
  /* WHAT HAS TO BE TRUE FOR THE BUG TO REPRODUCE is not that the box measured
     exactly zero — a few pixels of chrome survive the override — but that it was
     far shorter than what was written into it, by more than the 24px of slack
     the panel allows itself. Then the paint either believed it was at a foot
     that was about to move, or believed it was nowhere near one; both end with
     scrollTop at 0 and nothing to retry it. Measured: 7px of box around 237px of
     transcript. */
  ok("the log was far shorter than its content when it was painted",
     flat.scrollHeight - flat.clientHeight > 24 && flat.clientHeight < 24,
     JSON.stringify(flat));

  const forced = await page.evaluate(async () => {
    const st = document.getElementById("flatten-log");
    if (st) st.remove();
    const el = document.querySelector(".chatlog");
    // Short enough that the sample thread clearly overflows it: the assertion
    // below can only fail if being at the foot differs from being at the top by
    // more than the 24px slack the panel allows itself.
    el.style.height = "100px";
    // Two frames, which is what a ResizeObserver callback needs to land.
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    await new Promise(r => setTimeout(r, 150));
    return {
      scrollTop: Math.round(el.scrollTop),
      scrollHeight: el.scrollHeight,
      clientHeight: el.clientHeight,
      atBottom: el.scrollHeight - el.scrollTop - el.clientHeight < 24,
    };
  });
  ok("the forced case really does overflow, so the assertion below can fail",
     forced.scrollHeight > forced.clientHeight + 40, JSON.stringify(forced));
  // THE ASSERTION. Without the fix scrollTop stays 0 here.
  ok("a log that gets its height AFTER its content still opens at the foot",
     forced.atBottom === true, JSON.stringify(forced));

  /* THE BOX GETTING SHORTER RE-PINS, which is the second mechanism.
     SHORTER AND NOT TALLER, and getting that backwards made this assertion
     unable to fail: growing a box while the reader is at the foot keeps them
     there for free, because the browser CLAMPS scrollTop to the new maximum.
     Shrinking is what moves the foot away from them — the maximum grows and
     their scrollTop stays where it was. A rail opening beside the panel, a
     window made shorter, a status line appearing above the log: all of them
     take height away from it. */
  const grew = await page.evaluate(async () => {
    const el = document.querySelector(".chatlog");
    el.scrollTop = el.scrollHeight;         // at the foot
    el.dispatchEvent(new Event("scroll"));
    await new Promise(r => setTimeout(r, 60));
    el.style.height = "60px";               // the box loses height
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    await new Promise(r => setTimeout(r, 150));
    return {gap: el.scrollHeight - el.scrollTop - el.clientHeight,
            scrollHeight: el.scrollHeight, clientHeight: el.clientHeight};
  });
  ok("the shorter box still overflows, so this can fail",
     grew.scrollHeight > grew.clientHeight + 40, JSON.stringify(grew));
  ok("a box that loses height keeps the reader at the foot", grew.gap < 24,
     JSON.stringify(grew));

  /* AND A READER WHO SCROLLED UP IS LEFT ALONE — the half that must not
     regress, because being dragged back while reading history is worse than
     starting in the wrong place. Same box resize, from a scrolled-away state. */
  const held = await page.evaluate(async () => {
    const el = document.querySelector(".chatlog");
    el.scrollTop = 0;
    el.dispatchEvent(new Event("scroll"));
    await new Promise(r => setTimeout(r, 60));
    // A DIFFERENT HEIGHT FROM THE BLOCK ABOVE, or there is no size change and
    // the observer never fires — which made this pass without the guard it is
    // testing. Both blocks used 60px.
    el.style.height = "40px";               // a resize while they are up here
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    await new Promise(r => setTimeout(r, 150));
    return Math.round(el.scrollTop);
  });
  ok("a reader who scrolled up is not dragged back by a resize", held < 24,
     "scrollTop=" + held);

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
