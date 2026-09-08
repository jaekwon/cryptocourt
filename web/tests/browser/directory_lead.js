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

  /* WHAT EACH ROW SAYS ABOUT ITS COURT. The cell led with the coin's unit price
     and put the supply in the small line beneath, which asks the reader of a
     DIRECTORY to compare courts by unit price — a number that says nothing about
     a court on its own and reads as a market quote on a page for choosing what
     to read. It is the court's SIZE above and what was BURNED to build it below.
     MEASURED IN A BROWSER because this cell is filled asynchronously, after
     courtStats lands: the rendered row ships "reading…" and a source assertion
     alone cannot tell that the fill ever replaced it. */
  const cells = await page.evaluate(async () => {
    for (let i = 0; i < 30; i++) {
      const el = document.querySelector('.courtrow .px');
      if (el && !/reading…/.test(el.textContent)) break;
      await new Promise(r => setTimeout(r, 200));
    }
    return [...document.querySelectorAll('.courtrow')].slice(0, 4).map(row => {
      const px = row.querySelector('.px');
      const id = row.querySelector('.id');
      return px ? {big: (px.querySelector('b') || {}).textContent || "",
                   small: (px.querySelector('small') || {}).textContent || "",
                   // the row's own slug, to tell a COIN AMOUNT from a bare price
                   slug: ((id ? id.textContent : "").match(/\/([a-z0-9-]+)/) || [])[1] || ""}
                : null;
    }).filter(Boolean);
  });
  ok("every court row carries a figure for its court", cells.length > 0, JSON.stringify(cells));
  ok("...still reading, or filled — not stuck on the placeholder",
     cells.every(c => c.big || /reading|unavailable/.test(c.small)), JSON.stringify(cells));
  const filled = cells.filter(c => c.big);
  ok("at least one row filled from the sample", filled.length > 0, JSON.stringify(cells));
  /* THE COIN ON TOP, AND NAMED. cc() prints the amount with the court's own coin
     symbol, which a directory needs — every row is a different coin.
     THE SYMBOL IS ALSO WHAT TELLS THIS APART FROM A PRICE, and the first version
     of this arm missed that: it accepted any digits, so putting priceText back
     on top passed. A price is a bare number; a supply names what it counts. */
  ok("...leading with how much of the court's coin exists, named",
     filled.every(c => /\d/.test(c.big) && c.slug
                       && c.big.toLowerCase().includes(c.slug.toLowerCase())),
     JSON.stringify(filled));
  /* THE BURN UNDERNEATH — FOR EVERY COURT WHOSE SUPPLY WAS BURNED FOR. The meta
     court's was not: its coin arrives through ClaimMetaFranchise, which records
     no burn because the GNOT was already burned into whichever court the
     claimant bought. Its burn is therefore a structural zero, and "0.00 GNOT
     burned" beside a court that burned thousands is the exact line that produced
     the report — "how can there be no meta tokens when there were tokens burned
     for covid?". That row says where its coin comes from instead. */
  const burners = filled.filter(c => c.slug !== "meta");
  ok("...and the burn underneath, in GNOT, for every court burned for",
     burners.length > 0 && burners.every(c => /GNOT/.test(c.small) && /burn/.test(c.small)),
     JSON.stringify(filled));
  const metaRow = filled.find(c => c.slug === "meta");
  if (metaRow) {
    /* META'S BURN IS REAL, UNRECORDED, AND RECOVERABLE. Same curve as every
       court — a position implies the GNOT that reached it — so the figure is
       computed rather than read, and the label says where the burning happened.
       Read live at a position of 2,007,984,062: the curve gives 2,015,999,997
       µGNOT against 2,016.0 GNOT of entitlement actually consumed, the same
       number to a rounding remainder of one micro-unit. */
    ok("...while the meta court names where the burning happened",
       /on other courts/.test(metaRow.small), JSON.stringify(metaRow));
    ok("...and gives the figure rather than its structural zero",
       /GNOT/.test(metaRow.small) && !/^0(\.0+)? GNOT/.test(metaRow.small),
       JSON.stringify(metaRow));
  }
  /* AND NO PRICE. The unit price is on the court's own page, where a reader who
     wants to buy is already standing. "µGNOT/unit" was the old cell's caption
     and is the string that would come back if this were reverted. */
  ok("...and no unit price anywhere in the row",
     filled.every(c => !/\/unit/.test(c.big + c.small)), JSON.stringify(filled));

  ok("no page errors on the directory", errs.length === 0, errs.slice(0, 2).join(" | "));
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
