// THE FOLDERS SECTION IS THE COURT PAGE'S FILTER.
//
// Asked for: no separate chip row — the Folders rows above the search ARE the
// control. Nothing ticked by default, which shows everything; tick a folder and
// it lights up and the search, Open and Recently settled narrow to what is in
// it, counts included.
//
// NOTHING TICKED IS NOT "EVERY FOLDER TICKED", and the difference is the reason
// this default was chosen: a court's claims are not all filed, so an all-ticked
// default has to answer what becomes of the unfiled ones. An empty selection has
// nothing to answer, and the control reads as off when it is doing nothing.
//
// Measured rather than read: the effect is entirely layout and computed style,
// and the counts are rendered from data and rewritten live — an earlier version
// hid rows correctly while both headings went on announcing the full docket.
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
  await page.setViewport({width: 1280, height: 1100});
  await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
  await new Promise(r => setTimeout(r, 900));

  const snap = () => page.evaluate(() => {
    const shown = [...document.querySelectorAll(".docket a.crow.claimrow")]
      .filter(e => !e.classList.contains("fhide") && !e.classList.contains("qhide"));
    const c = k => { const e = document.querySelector(`[data-count="${k}"]`); return e ? +e.textContent.trim() : null; };
    const rows = [...document.querySelectorAll(".foldsel")];
    return {rows: shown.length, open: c("open"), settled: c("settled"),
            folders: rows.length,
            ticked: rows.filter(r => r.getAttribute("aria-checked") === "true").length,
            tint: rows[0] ? getComputedStyle(rows[0]).backgroundColor : null,
            chipRow: !!document.getElementById("foldbar")};
  });

  const a = await snap();
  ok("the Folders rows are the control", a.folders >= 2, JSON.stringify(a));
  /* THE SECOND ROW OF CHIPS UNDER THE SEARCH IS GONE. It duplicated the Folders
     section and flattened subfolders into entries of their own. */
  ok("...and there is no separate chip row", a.chipRow === false);
  ok("nothing is ticked to begin with", a.ticked === 0, JSON.stringify(a));
  ok("...so every claim is shown", a.rows > 0 && a.open > 0, JSON.stringify(a));
  ok("...and no folder is tinted", a.tint === "rgba(0, 0, 0, 0)", String(a.tint));

  const label = await page.evaluate(() => {
    const r = document.querySelector(".foldsel"); r.click(); return r.querySelector(".t").textContent.trim();
  });
  await new Promise(r => setTimeout(r, 250));
  const b2 = await snap();
  ok("ticking a folder narrows the page to it", b2.rows < a.rows, `${a.rows} -> ${b2.rows} (${label})`);
  ok("...Open counts down with it", b2.open < a.open, `${a.open} -> ${b2.open}`);
  ok("...and Recently settled too", b2.settled < a.settled, `${a.settled} -> ${b2.settled}`);
  ok("...the row reads as checked", b2.ticked === 1, JSON.stringify(b2));
  /* LIGHT PURPLE, asked for by name. Asserted as "some tint, not transparent"
     rather than as a hex: the exact colour is the accent mixed at 14% and is a
     design value, but "the ticked row is visibly lit" is the requirement. */
  ok("...and is visibly lit", b2.tint !== "rgba(0, 0, 0, 0)" && b2.tint !== a.tint, String(b2.tint));

  /* A FOLDER BRINGS ITS SUBFOLDERS. "Everything in that folder" includes the
     drawers inside it, and a chain subfolder's path is its own fid rather than
     "parent.child", so there is no prefix to test — the row carries its whole
     subtree. */
  const subtree = await page.evaluate(async () => {
    // THE ROW IS FOUND BY WHAT IT SAYS, not by what the attribute already
    // contains. Looking for a row that has several keys made this assertion
    // skip itself the moment the keys stopped being written — a mutant that
    // carried only the folder's own path passed by making the case disappear.
    const r = [...document.querySelectorAll(".foldsel")].find(x => /subfolder/.test(x.textContent));
    if (!r) return {noParent: true};
    const keys = (r.getAttribute("data-fold-keys") || "").split(" ").filter(Boolean);
    // and behaviourally: ticking the parent must reveal a claim filed in a CHILD.
    // This probe drives the selection, so it snapshots and puts back what it
    // found — leaving it cleared made the two checks after it read a state
    // nobody had asked for, and both failed for the probe's reasons.
    const saved = new Set(FOLD_ON);
    FOLD_ON = new Set(); applyFolders();
    r.click(); await new Promise(z => setTimeout(z, 150));
    const own = keys[0];
    const childClaimShown = [...document.querySelectorAll(".docket a.crow.claimrow")]
      .filter(e => !e.classList.contains("fhide"))
      .some(e => !(e.getAttribute("data-fold") || "").split(" ").includes(own));
    FOLD_ON = saved; applyFolders(); await new Promise(z => setTimeout(z, 150));
    return {keys: keys.length, childClaimShown};
  });
  ok("a folder with subfolders carries its whole subtree",
     subtree && !subtree.noParent && subtree.keys > 1, JSON.stringify(subtree));
  ok("...so ticking the parent shows a claim filed in a child",
     subtree && subtree.childClaimShown === true, JSON.stringify(subtree));

  /* The row still has a way through to the folder page: a control that navigates
     on click cannot also select, so the link moved to its own affordance. */
  const withQ = await page.evaluate(async () => {
    document.getElementById("q").value = "the"; applyQ("the");
    await new Promise(r => setTimeout(r, 150));
    return [...document.querySelectorAll(".docket a.crow.claimrow")]
      .filter(e => !e.classList.contains("fhide") && !e.classList.contains("qhide")).length;
  });
  ok("a search never reaches outside the ticked folders", withQ <= b2.rows, `${withQ} vs ${b2.rows}`);
  await page.evaluate(() => { document.getElementById("q").value = ""; applyQ(""); });
  await new Promise(r => setTimeout(r, 150));

  await page.evaluate(() => document.querySelector(".foldsel").click());
  await new Promise(r => setTimeout(r, 250));
  const c3 = await snap();
  ok("unticking it puts every row and count back",
     c3.rows === a.rows && c3.open === a.open && c3.settled === a.settled && c3.ticked === 0,
     JSON.stringify(c3));

  const openLink = await page.evaluate(() => {
    const l = document.querySelector(".foldsel .foldopen");
    return l ? {href: l.getAttribute("href"), text: l.textContent.trim()} : null;
  });
  ok("the folder page is still reachable from the row",
     openLink && /^#\/c\/[a-z0-9-]+\/f\//.test(openLink.href), JSON.stringify(openLink));
  /* AND THAT LINK IS NOT A TOGGLE. It sits inside the row, so without a guard the
     row's own handler fires on it and a reader trying to open a folder selects it
     instead — then lands on the folder page with the court page's filter changed
     behind them. */
  const linkClick = await page.evaluate(async () => {
    // FOLD_ON, not the DOM: this click really does navigate, so the rows are
    // gone by the time we look. The selection is the thing that must not have
    // moved, and it outlives the page it was made on.
    const before = FOLD_ON.size;
    document.querySelector(".foldsel .foldopen")
      .dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true}));
    await new Promise(r => setTimeout(r, 400));
    return {before, after: FOLD_ON.size, hash: location.hash};
  });
  ok("...and following it does not tick the folder",
     linkClick && linkClick.after === linkClick.before, JSON.stringify(linkClick));
  ok("...it navigates there instead",
     linkClick && /^#\/c\/[a-z0-9-]+\/f\//.test(linkClick.hash), JSON.stringify(linkClick));


  ok("no page errors from the filter", errs.length === 0, errs.slice(0, 2).join(" | "));
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
