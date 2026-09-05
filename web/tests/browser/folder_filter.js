// FOLDERS AS THE PAGE'S TOP KNOB.
//
// Asked for: all folders selected by default so you see everything, and
// unticking one makes its claims unavailable to search, Open and Recently
// settled — counts included.
//
// Measured rather than read, for two reasons. The filter is a class toggle whose
// whole effect is on layout, and — the one that actually bit — the COUNTS are
// rendered from the data and have to be rewritten live. A first version hid the
// rows correctly and left both counts announcing a docket the page was no longer
// showing, which reads as a bug in the numbers rather than a filter working.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 160)));
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await page.setViewport({width: 1280, height: 1000});
  await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
  await new Promise(r => setTimeout(r, 900));

  const snap = () => page.evaluate(() => {
    const shown = [...document.querySelectorAll(".docket a.crow.claimrow")]
      .filter(e => !e.classList.contains("fhide") && !e.classList.contains("qhide"));
    const c = k => { const e = document.querySelector(`[data-count="${k}"]`); return e ? +e.textContent.trim() : null; };
    return {rows: shown.length, open: c("open"), settled: c("settled"),
            chips: [...document.querySelectorAll("#foldbar [data-fold-key]")].length,
            pressed: [...document.querySelectorAll('#foldbar [data-fold-key][aria-pressed="true"]')].length};
  });

  const a = await snap();
  ok("the court page carries a folder chip for every drawer", a.chips >= 2, JSON.stringify(a));
  /* EVERYTHING IS SHOWN BY DEFAULT. The knob has to be discoverable without
     changing what a first-time reader sees, so every chip starts pressed. */
  ok("...all of them ticked to begin with", a.pressed === a.chips, JSON.stringify(a));
  ok("...and rows on the page to filter", a.rows > 0 && a.open > 0, JSON.stringify(a));

  const label = await page.evaluate(() => {
    const b = document.querySelector("#foldbar [data-fold-key]"); b.click(); return b.textContent.trim();
  });
  await new Promise(r => setTimeout(r, 250));
  const b2 = await snap();
  ok("unticking a folder takes its claims off the page", b2.rows < a.rows, `${a.rows} -> ${b2.rows} (${label})`);
  /* THE COUNTS ARE THE ASK. Rows hiding while the heading still says 8 is the
     state this was written to prevent. */
  ok("...and Open counts down with them", b2.open < a.open, `${a.open} -> ${b2.open}`);
  ok("...and so does Recently settled", b2.settled < a.settled, `${a.settled} -> ${b2.settled}`);
  ok("...with the chip showing itself unticked",
     b2.pressed === a.pressed - 1, `${a.pressed} -> ${b2.pressed}`);

  /* THE FILTER COMPOSES WITH THE SEARCH rather than replacing it: a query over a
     filtered page must not resurrect a row the folder took. */
  const withQ = await page.evaluate(async () => {
    const i = document.getElementById("q");
    i.value = "the"; applyQ("the");
    await new Promise(r => setTimeout(r, 150));
    return [...document.querySelectorAll(".docket a.crow.claimrow")]
      .filter(e => !e.classList.contains("fhide") && !e.classList.contains("qhide")).length;
  });
  ok("a search never un-hides a folder the reader unticked", withQ <= b2.rows, `${withQ} vs ${b2.rows}`);
  await page.evaluate(() => { document.getElementById("q").value = ""; applyQ(""); });
  await new Promise(r => setTimeout(r, 150));

  /* A CROSS-FILED CLAIM NEEDS ALL ITS FOLDERS UNTICKED, and the fixture has no
     such claim — every demo row sits in exactly one drawer — so no rendered page
     can tell `every` from `some`. The case is CONSTRUCTED instead: a row is given
     two folders and one of them is unticked, which is the only reading under
     which the counts add up. A claim you can still reach through a ticked drawer
     has not been filtered out of that drawer. */
  const cross = await page.evaluate(async () => {
    const row = document.querySelector(".docket a.crow.claimrow");
    const off = [...FOLD_OFF][0];
    const other = [...document.querySelectorAll("#foldbar [data-fold-key]")]
      .map(b => b.getAttribute("data-fold-key")).find(k => k !== off);
    row.setAttribute("data-fold", off + " " + other);   // in both drawers
    applyFolders();
    await new Promise(r => setTimeout(r, 100));
    const hiddenWithOneOff = row.classList.contains("fhide");
    FOLD_OFF.add(other); applyFolders();
    await new Promise(r => setTimeout(r, 100));
    const hiddenWithBothOff = row.classList.contains("fhide");
    FOLD_OFF.delete(other);
    return {hiddenWithOneOff, hiddenWithBothOff};
  });
  ok("a claim in two drawers survives one of them being unticked",
     cross && cross.hiddenWithOneOff === false, JSON.stringify(cross));
  ok("...and goes only when both are", cross && cross.hiddenWithBothOff === true, JSON.stringify(cross));

  /* THE CAPTION COUNTS THE SAME ROWS THE PAGE SHOWS. A match tally that includes
     folded rows reads as the filter having failed, in the one place that states a
     number in words. */
  const cap = await page.evaluate(async () => {
    const i = document.getElementById("q");
    i.value = "the"; applyQ("the");
    await new Promise(r => setTimeout(r, 150));
    const shown = [...document.querySelectorAll("#qscope [data-q]")]
      .filter(e => !e.classList.contains("fhide") && !e.classList.contains("qhide")).length;
    const txt = (document.getElementById("qcap") || {}).textContent || "";
    const n = (txt.match(/\d+/) || [])[0];
    return {shown, capNum: n == null ? null : +n, txt: txt.slice(0, 60)};
  });
  ok("the search caption counts only what the folders left visible",
     cap && cap.capNum != null && cap.capNum <= cap.shown, JSON.stringify(cap));
  await page.evaluate(() => { document.getElementById("q").value = ""; applyQ(""); });
  await new Promise(r => setTimeout(r, 150));

  await page.evaluate(() => document.querySelector("#foldall").click());
  await new Promise(r => setTimeout(r, 250));
  const c3 = await snap();
  ok("'all' puts every row and every count back",
     c3.rows === a.rows && c3.open === a.open && c3.settled === a.settled, JSON.stringify(c3));

  ok("no page errors from the filter", errs.length === 0, errs.slice(0, 2).join(" | "));
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
