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
    const chip = k => { const e = document.querySelector(`.gchips [data-show="${k}"] .n`); return e ? +e.textContent.trim() : null; };
    const head = document.querySelector("[data-qcount]");

    const rows = [...document.querySelectorAll(".foldsel")];
    return {rows: shown.length, open: c("open"), settled: c("settled"),
            chipOpen: chip("open"), chipAll: chip("all"),
            head: head ? head.textContent.trim() : null,
            folders: rows.length,
            ticked: rows.filter(r => r.getAttribute("aria-checked") === "true").length,
            tint: rows[0] ? getComputedStyle(rows[0]).backgroundColor : null,
            chipRow: !!document.getElementById("foldbar")};
  });

  const a = await snap();
  ok("the Folders rows are the control", a.folders >= 2, JSON.stringify(a));
  /* NO CLAIM IS ON THIS PAGE TWICE. "Still flaggable" is the chain's own list
     and overlaps the docket by nature — a settled claim stays flaggable until
     its rewards are opened — so it repeated four of orem's claims under a
     second heading. Narrowed to a folder of three that read as six. Reported. */
  const twice = await page.evaluate(() => {
    const ids = [...document.querySelectorAll("#qscope .crow.claimrow")]
      .map(r => (r.getAttribute("href") || "").split("/").pop());
    return [...new Set(ids.filter((v, i) => ids.indexOf(v) !== i))];
  });
  ok("...and no claim is listed twice on the page", twice.length === 0, JSON.stringify(twice));
  /* THE SECOND ROW OF CHIPS UNDER THE SEARCH IS GONE. It duplicated the Folders
     section and flattened subfolders into entries of their own. */
  ok("...and there is no separate chip row", a.chipRow === false);
  ok("nothing is ticked to begin with", a.ticked === 0, JSON.stringify(a));
  ok("...so every claim is shown", a.rows > 0 && a.open > 0, JSON.stringify(a));
  ok("...and no folder is tinted", a.tint === "rgba(0, 0, 0, 0)", String(a.tint));

  /* THE ROW STILL HAS TO LOOK LIKE A ROW. Every docket rule was written as
     `.docket a` — display, grid, padding, the rule between rows — so turning the
     folder row into a div for the checkbox left it with no layout at all: five
     stacked blocks per folder, three folders filling the screen. The behaviour
     tests all passed on that page, because none of them looked at it. */
  const layout = await page.evaluate(() => {
    const g = e => { const s = getComputedStyle(e);
      return {display: s.display, cols: s.gridTemplateColumns.split(/\s+/).filter(Boolean).length,
              h: Math.round(e.getBoundingClientRect().height)}; };
    const f = document.querySelector(".foldsel");
    const kids = [...f.children].map(e => Math.round(e.getBoundingClientRect().height));
    const l = f.querySelector(".foldopen");
    return {folder: g(f), kids, tallest: Math.max(...kids),
            link: {display: getComputedStyle(l).display,
                   wFrac: +(l.getBoundingClientRect().width / f.getBoundingClientRect().width).toFixed(2)}};
  });
  ok("the folder row is laid out as a docket row",
     layout.folder.display === "grid" && layout.folder.cols >= 3, JSON.stringify(layout));
  /* Measured against its own children rather than against a claim row: the row
     is one line of columns, so its height is the tallest column plus padding.
     Stacked, it is their sum — which is what the div was doing. */
  ok("...on one line, not stacked",
     layout.folder.h <= layout.tallest + 40, JSON.stringify(layout));
  /* AND THE LINK INSIDE IT IS NOT ITSELF A ROW. The docket styles rows by
     selecting anchors; the row now contains one, and as a descendant selector
     that rule turned the "open →" link into a full-width bordered block of its
     own. It is a pill in the last column. */
  ok("...and its link is a pill, not a row of its own",
     layout.link.display !== "grid" && layout.link.wFrac < 0.4, JSON.stringify(layout.link));

  const label = await page.evaluate(() => {
    const r = document.querySelector(".foldsel"); r.click(); return r.querySelector(".t").textContent.trim();
  });
  await new Promise(r => setTimeout(r, 250));
  const b2 = await snap();
  ok("ticking a folder narrows the page to it", b2.rows < a.rows, `${a.rows} -> ${b2.rows} (${label})`);
  ok("...Open counts down with it", b2.open < a.open, `${a.open} -> ${b2.open}`);
  ok("...and Recently settled too", b2.settled < a.settled, `${a.settled} -> ${b2.settled}`);
  ok("...the row reads as checked", b2.ticked === 1, JSON.stringify(b2));
  /* THE CHIP AND THE HEADING NAME THE SAME LIST, so they cannot hold different
     numbers. Both of these were rendered once from the window totals and never
     touched again: the chip sat at OPEN 8 over a section headed OPEN 2. */
  ok("...the SHOW chip agrees with the section it names",
     b2.chipOpen === b2.open, `chip ${b2.chipOpen} vs heading ${b2.open}`);
  ok("...and ALL counts the two sections it covers",
     b2.chipAll === b2.open + b2.settled, JSON.stringify(b2));
  ok("...the figure over the search box comes down too",
     b2.head !== a.head && /^all \d+ /.test(b2.head || ""), `${a.head} -> ${b2.head}`);
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
    // contains. That couples it to the copy, which is the intended trade: when
    // "subfolder" became "subset" this went red rather than quietly finding no
    // row, which is exactly the behaviour the next paragraph asks for. Looking for a row that has several keys made this assertion
    // skip itself the moment the keys stopped being written — a mutant that
    // carried only the folder's own path passed by making the case disappear.
    const r = [...document.querySelectorAll(".foldsel")].find(x => /subset/.test(x.textContent));
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
  ok("...the chips and the figure with them",
     c3.chipOpen === a.chipOpen && c3.chipAll === a.chipAll && c3.head === a.head,
     `${JSON.stringify(c3)} vs ${JSON.stringify(a)}`);

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


  /* THE CHAIN'S LIST, ON THE COURT THAT HAS SOMETHING TO PUT IN IT. Every row
     of orem's was a claim from the docket above, so that list is gone from the
     page. annex keeps one — a claim hidden by moderation, absent from the
     docket and still policeable, which is the whole reason the section exists.
     Dedupe had to leave that standing, or the fix would have deleted the only
     rows that were ever worth showing. */
  await page.goto(PAGE + '#/c/annex', {waitUntil: 'networkidle0'});
  await new Promise(r => setTimeout(r, 800));
  const annex = await page.evaluate(async () => {
    const idsOf = e => [...e].map(r => (r.getAttribute("href") || "").split("/").pop());
    const all = idsOf(document.querySelectorAll("#qscope .crow.claimrow"));
    const sec = document.querySelector('[data-group="review"]');
    if(!sec) return {noSection: true, all};
    const out = {dups: [...new Set(all.filter((v, i) => all.indexOf(v) !== i))],
                 restHead: (sec.querySelector("[data-chaincount]") || {}).textContent,
                 rev: idsOf(sec.querySelectorAll(".crow.claimrow")),
                 onDocket: idsOf(document.querySelectorAll('section[data-qsec] .crow.claimrow:not(.offp)'))};
    /* THE FOLDER REACHES THE CHAIN'S LIST, both ways. annex/5 is filed in
       Reading room and is the list's only row, so that folder must keep it and
       any other folder must take it away. These rows carry no data-q — the
       filter reads the folder off them, not off the search's attribute. */
    const pick = async name => {
      const r = [...document.querySelectorAll(".foldsel")].find(x => x.textContent.includes(name));
      FOLD_ON = new Set(); applyFolders(); r.click();
      await new Promise(z => setTimeout(z, 150));
      return {rows: idsOf(sec.querySelectorAll(".crow.claimrow:not(.fhide)")),
              gone: sec.classList.contains("qhide"),
              head: (sec.querySelector("[data-chaincount]") || {}).textContent,
              chipGone: !!document.querySelector('.gchips [data-show="review"].ghide')};
    };
    out.inFolder = await pick("Reading room");
    out.otherFolder = await pick("Deeds");
    FOLD_ON = new Set(); applyFolders();
    return out;
  });
  ok("the chain's list keeps what the docket does not show",
     !annex.noSection && annex.rev.length > 0 && annex.rev.every(id => !annex.onDocket.includes(id)),
     JSON.stringify(annex));
  ok("...with nothing listed twice there either", !annex.noSection && annex.dups.length === 0,
     JSON.stringify(annex.dups));
  ok("...and the folder it is filed in keeps it",
     annex.inFolder && annex.inFolder.rows.length > 0 && !annex.inFolder.gone,
     JSON.stringify(annex.inFolder));
  ok("...while any other folder takes it away",
     annex.otherFolder && annex.otherFolder.rows.length === 0 && annex.otherFolder.gone,
     JSON.stringify(annex.otherFolder));
  /* THE HEADING COUNTS WHAT IS UNDER IT, in both states. At rest it is the bare
     figure; under a folder it names the chain's queue as the denominator, so
     "1 of 1" is the list saying it is showing you all of it. A heading that
     stays on its rest figure while the rows below it change is the bug this
     whole thread started from. */
  ok("...and the heading follows the rows into the folder",
     annex.inFolder.head !== annex.restHead && /^\d+ of \d+$/.test(annex.inFolder.head || ""),
     `rest ${JSON.stringify(annex.restHead)} -> ${JSON.stringify(annex.inFolder.head)}`);
  ok("...which takes the emptied chip with it",
     annex.otherFolder && annex.otherFolder.chipGone === true && !annex.inFolder.chipGone,
     JSON.stringify([annex.inFolder, annex.otherFolder]));

  /* THE CONTROL IS A WEDJAT, AND EXACTLY ONE EYE SHOWS. Both are in the markup
     and the swap is pure CSS off the row's own aria-checked, which is the same
     attribute the filter reads — so this asserts the two cannot drift: a row
     that filters as ticked but paints the shut eye, or paints both, is the whole
     failure mode of driving a visual from a duplicate of the state.
     DISPLAY, NOT PRESENCE. Both elements exist in either state; querySelector
     finds them either way, so only a computed style can tell which one a reader
     actually sees. Asserted in BOTH directions and on BOTH rows, because "the
     open eye is showing" alone would pass on a control stuck open.
     Ablated: dropping the [aria-checked="true"] .eyeopen rule fails the ticked
     arm alone (both eyes report none — the row loses its control entirely, which
     is a louder signature than the shut eye showing); deleting the
     .foldsel .eyeopen{display:none} default fails the "exactly one" arm on the
     unticked row with two visible eyes, and leaves the ticked arm passing. */
  const eyes = await page.evaluate(() => {
    const rows = [...document.querySelectorAll("#qscope .foldsel")];
    if (rows.length < 2) return {few: rows.length};
    const look = r => {
      const o = r.querySelector(".eyeopen"), sh = r.querySelector(".eyeshut");
      return {checked: r.getAttribute("aria-checked"),
              both: !!(o && sh),
              open: o ? getComputedStyle(o).display : "absent",
              shut: sh ? getComputedStyle(sh).display : "absent"};
    };
    rows.forEach(r => { if (r.getAttribute("aria-checked") === "true") r.click(); });
    rows[0].click();                                   // tick exactly the first
    return {on: look(rows[0]), off: look(rows[1])};
  });
  ok("both eyes ship in every folder row",
     !eyes.few && eyes.on.both && eyes.off.both, JSON.stringify(eyes));
  ok("a ticked folder shows the open eye and only that",
     !eyes.few && eyes.on.checked === "true"
       && eyes.on.open !== "none" && eyes.on.shut === "none", JSON.stringify(eyes.on));
  ok("an unticked folder shows the shut eye and only that",
     !eyes.few && eyes.off.checked === "false"
       && eyes.off.shut !== "none" && eyes.off.open === "none", JSON.stringify(eyes.off));

  /* THE SEARCH CAPTION NAMES TWO NOUNS AND COUNTS BOTH. It read "all 22 claims
     and folders" — one figure for both — which parses as "22 claims-and-folders"
     and leaves a reader unable to tell whether the folders listed directly above
     are inside that number or extra to it. They were inside it.
     ASSERTED AS ARITHMETIC, not as a sentence. The claim figure has to follow
     the fold filter while the folder figure does NOT, and that pair is the whole
     behaviour: a caption whose two numbers both froze, or both moved, would
     match any regex that only checked the shape. So the ticked reading is
     required to be strictly smaller in claims and identical in folders, and the
     folder figure is checked against the rows actually on screen rather than
     against a constant.
     Ablated against a control run that fires nothing, with the counts as
     measured rather than as guessed:
       - sum the two back into one figure -> 3 arms, all three of these: the
         regex stops matching, so both figures read null.
       - claim count stops following the fold filter (drop the !folded pass) ->
         2 arms, including this block's third, with the two readings identical.
       - folder figure counts a constant instead of the rows -> 5 arms, this
         block's second among them.
     THE FIRST ATTEMPT AT THE SECOND ABLATION FIRED NOTHING, and it was the
     instrument that was broken, not the assertion: it froze the count through a
     `let CAPREST` while assigning to `window.CAPREST`, which are different
     bindings, so the mutation was a no-op and the run was green for the same
     reason an unmodified one is. Recorded because a no-op ablation reads exactly
     like a vacuous test, and the difference is only visible if you go back and
     check that the mutation took. */
  const cap = await page.evaluate(() => {
    const read = () => {
      const e = document.querySelector("[data-qcount]");
      const m = (e ? e.textContent.trim() : "").match(/^all ([\d,]+) claims?(?: and ([\d,]+) sets?)?$/);
      return {text: e ? e.textContent.trim() : null,
              claims: m ? +m[1].replace(/,/g, "") : null,
              folders: m && m[2] ? +m[2].replace(/,/g, "") : null};
    };
    const rows = [...document.querySelectorAll("#qscope .foldsel")];
    rows.forEach(r => { if (r.getAttribute("aria-checked") === "true") r.click(); });
    const rest = read();
    rows[0] && rows[0].click();
    const on = read();
    rows[0] && rows[0].click();
    return {rest, on, onScreenFolders: rows.length};
  });
  ok("the search caption counts claims and folders separately",
     cap.rest.claims !== null && cap.rest.folders !== null, JSON.stringify(cap.rest));
  ok("...with the folder figure matching the rows on screen",
     cap.rest.folders === cap.onScreenFolders,
     `${cap.rest.folders} vs ${cap.onScreenFolders} rows`);
  ok("...and the claim figure following the filter while the folders hold",
     cap.on.claims !== null && cap.on.claims < cap.rest.claims
       && cap.on.folders === cap.rest.folders,
     `rest ${JSON.stringify(cap.rest.text)} -> ticked ${JSON.stringify(cap.on.text)}`);

  ok("no page errors from the filter", errs.length === 0, errs.slice(0, 2).join(" | "));
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
