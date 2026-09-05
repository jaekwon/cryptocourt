// THE DIRECTORY LEADS WITH COURTS, NOT WITH AN INVITATION TO MAKE ONE.
//
// The page opened with "Courts of record", a paragraph explaining what a court
// is, and two buttons for starting one — so a reader who came to READ the
// directory scrolled past an invitation to WRITE it. Both moved below the list.
//
// Measured, not read: the ordering is a layout fact, and the markup is one
// string either way. Same argument rowscope_layout.js makes about `.line`.
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
  await page.goto(PAGE + '#/', {waitUntil: 'networkidle0'});
  await new Promise(r => setTimeout(r, 900));

  const geo = await page.evaluate(() => {
    const T = e => Math.round(e.getBoundingClientRect().top);
    const h1 = document.querySelector("h1.page-h");
    const courts = [...document.querySelectorAll(".sec-h")].find(e => /Courts/.test(e.textContent));
    const rows = document.querySelectorAll(".docket a.courtrow");
    return {
      h1: h1 && h1.textContent.trim(),
      h1Top: h1 ? T(h1) : null,
      courtsTop: courts ? T(courts) : null,
      firstRowTop: rows.length ? T(rows[0]) : null,
      buttons: [...document.querySelectorAll(".lead-row .btn")].map(e => e.textContent.trim()),
      // ONE PAGE HEADING, counted INSIDE .main. The document has a second h1 —
      // the site brand in the rail — which is pre-existing and outside the page
      // body; counting document-wide asserted a fact about the masthead and
      // failed for a reason that had nothing to do with this change.
      h1Count: document.querySelectorAll(".main h1").length,
    };
  });

  ok("the directory still names itself", geo.h1 === "Courts of record", String(geo.h1));
  ok("...exactly once in the page body", geo.h1Count === 1, String(geo.h1Count));
  ok("the courts section comes before it", geo.courtsTop < geo.h1Top,
     `courts ${geo.courtsTop} vs h1 ${geo.h1Top}`);
  ok("...and so does the first court row", geo.firstRowTop < geo.h1Top,
     `row ${geo.firstRowTop} vs h1 ${geo.h1Top}`);
  /* THE VERB CHANGED WITH THE PLACE. "Start a court" read as the page's purpose
     when it sat at the top; at the bottom it is an offer, and "Create a new
     court" is what an offer says. */
  ok("the primary button invites creating a new court",
     geo.buttons.some(b => /Create a new court/.test(b)), geo.buttons.join(" | "));
  ok("...and nothing still says 'Start a court'",
     !geo.buttons.some(b => /Start a court/.test(b)), geo.buttons.join(" | "));

  /* THE HELPER OPENS. A link that is positioned well and inert is worse than one
     in the wrong place — the same check buy_details.js makes of its own dialog. */
  const modal = await page.evaluate(async () => {
    const link = document.querySelector('[data-help="help-newcourt"]');
    if (!link) return null;
    const before = (document.querySelector("#help-newcourt") || {}).open === true;
    link.click();
    await new Promise(r => setTimeout(r, 200));
    const d = document.querySelector("#help-newcourt");
    return {before, after: d ? d.open === true : null,
            says: d ? /slug|moderator|polish/.test(d.textContent) : false};
  });
  ok("the helper exists and starts closed", modal && modal.before === false, JSON.stringify(modal));
  ok("...and opens on the link", modal && modal.after === true, JSON.stringify(modal));
  ok("...saying what starting one actually involves", modal && modal.says === true);

  ok("no page errors on the directory", errs.length === 0, errs.slice(0, 2).join(" | "));
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
