// WHERE THE DETAILS TRIGGER LANDS, measured rather than read. It reads "see details"
// now; the arrow went with the line described below, since an arrow is this page's
// mark for leaving and a dialog does not leave.
//
// It was written at the end of the "You pay" value — after "µGNOT/unit · 0.4%
// voice" — which is fine at 1280px and falls apart at 390px: the value wraps
// across four lines and the link ends up on one of its own, roughly 120px below
// the Buy button it belongs beside. Reported as: it should be next to the
// button, or short enough to fit.
//
// That value is gone entirely now — merged into the dialog, which already carried
// both its figures verbatim — so the wrap that started this cannot recur. The
// measurements stay: what they actually pin is that the trigger sits with the button
// rather than in whatever block happens to precede it, and that is a property of the
// layout and not of the line that used to be there.
//
// A source test cannot see this. The markup is one string either way; what
// changed is which flex container the button is in, and only a laid-out page can
// say whether the two ended up side by side. Same argument rowscope_layout.js
// makes about `.line`.
//
// Measured at the narrow width because that is the one that broke. Desktop is
// asserted too, so a fix that only helps mobile — or one that fixes mobile by
// stacking the row everywhere — is caught.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });

  const measure = async (w, h) => {
    await page.setViewport({width: w, height: h});
    await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
    await new Promise(r => setTimeout(r, 900));
    return page.evaluate(() => {
      const amt = document.querySelector('#buyamt');
      if (!amt) return {noPanel: true};
      const btn = document.querySelector('#buyactions .btn');
      const link = document.querySelector('[data-help="help-buy"]');
      if (!btn || !link) return {btn: !!btn, link: !!link};
      const b = btn.getBoundingClientRect(), l = link.getBoundingClientRect();
      return {
        // ONE LINK, NOT ONE THAT HAPPENS TO BE FIRST. querySelector takes the
        // first in document order, and #buyactions precedes #buyrows2 — so
        // putting a second copy back on the receipt line left every measurement
        // above passing. Counted, so the move is a move rather than a copy.
        count: document.querySelectorAll('[data-help="help-buy"]').length,
        // Vertical overlap is the question, not equal tops: a text link and a
        // padded button never share a top edge even when they sit side by side.
        overlap: Math.min(b.bottom, l.bottom) - Math.max(b.top, l.top),
        linkH: Math.round(l.height),
        gapBelow: Math.round(l.top - b.bottom),
        sameRow: l.left >= b.right - 1,
        dialog: !!document.querySelector('#help-buy'),
        linkText: link.textContent.trim(),
      };
    });
  };

  for (const [w, h] of [[390, 844], [1280, 1000]]) {
    const r = await measure(w, h);
    const at = `@${w}px`;
    ok(`the buy panel renders ${at}`, r && !r.noPanel && r.linkText, JSON.stringify(r));
    if (!r || r.noPanel || !r.linkText) continue;
    /* ADJACENT, which is as strong as this can honestly be asserted. On desktop
       the join panel sits in a 250px rail and the Buy button alone is 207px, so
       "beside" is arithmetically impossible: "details →" needs 279px of 250 and
       even "more →" needs 269. Measured, not assumed — the shorter label was
       tried and is a smaller version of the same overflow, not a fix.
       So: beside the button where there is room, and directly beneath it where
       there is not. Both are adjacent; the bug was neither. */
    ok(`details is adjacent to the Buy button ${at}`,
       r.overlap > 0 || r.gapBelow < 16, JSON.stringify(r));
    // The shape of the bug, as a number: it used to land ~120px down, in a
    // different block entirely.
    ok(`...never stranded away from it ${at}`, r.gapBelow < 16, JSON.stringify(r));
    // Where there IS room, it must actually take it rather than wrap anyway.
    if (r.overlap > 0) ok(`...and takes the room when there is room ${at}`, r.sameRow, JSON.stringify(r));
    /* THE DIALOG STAYS REACHABLE. The button moved out of #buyrows2 and the
       dialog did not — it is rebuilt with the figures on every keystroke, which
       is what keeps them in step — so the two are no longer siblings and the
       lookup is by id. If that ever breaks, the link opens nothing. */
    ok(`the dialog it opens is present ${at}`, r.dialog, JSON.stringify(r));
    ok(`...and there is exactly one of it ${at}`, r.count === 1, JSON.stringify(r));
    /* THE TARGET, which centring the link quietly halved. An earlier draft set
       align-self:center so the text link would not stretch to the button's
       height; the label is centred either way — the row centres it — so all
       that bought was a 23px target next to a 42px button, under the 24px this
       file holds itself to elsewhere. Pinned as a number because it is invisible:
       both versions look identical. */
    ok(`...with a target at least 24px tall ${at}`, r.linkH >= 24, JSON.stringify(r));
  }

  // And it really opens: a link that is positioned well and inert is worse than
  // one that is merely in the wrong place.
  await page.setViewport({width: 390, height: 844});
  await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
  await new Promise(r => setTimeout(r, 900));
  const opened = await page.evaluate(async () => {
    const link = document.querySelector('[data-help="help-buy"]');
    if (!link) return null;
    link.click();
    await new Promise(r => setTimeout(r, 200));
    const d = document.querySelector('#help-buy');
    return d ? d.open === true : null;
  });
  ok("clicking it opens the dialog", opened === true, String(opened));

  /* AND IT GOES WHEN THERE IS NOTHING TO DETAIL. buyRowsHtml emits the dialog only
     for a quote that mints something, so a details link surviving an unquotable
     amount opens a dialog about figures the panel is not showing.
     Typed rather than constructed: the link is redrawn by the keystroke handler,
     which is the path that has to get this right.
     THE SECOND HALF USED TO CHECK THE "You pay" LINE, which has been merged into the
     dialog — both its figures were in there verbatim, and in a 250px rail the copy in
     front wrapped to four lines. So the container is checked for being EMPTY rather
     than for lacking one line: it holds the dialog and nothing else now, and an
     unquotable amount must leave it with neither. */
  const gone = await page.evaluate(async () => {
    const amt = document.querySelector('#buyamt');
    if (!amt) return null;
    amt.value = "not a number";
    amt.dispatchEvent(new Event('input', {bubbles: true}));
    await new Promise(r => setTimeout(r, 300));
    const box = document.querySelector('#buyrows2');
    return {links: document.querySelectorAll('[data-help="help-buy"]').length,
            dialogs: document.querySelectorAll('#buyrows2 dialog').length,
            text: (box?.textContent || "").trim(),
            framed: !!box && box.className.trim() !== ""};
  });
  ok("an unquotable amount leaves no details link", gone && gone.links === 0, JSON.stringify(gone));
  ok("...and nothing behind it either", gone && gone.dialogs === 0 && gone.text === "",
     JSON.stringify(gone));
  // The container carried .ticket .buyrcpt while it held a line. Holding only a
  // dialog, a frame would draw an empty box with registration marks on it.
  ok("...and the container draws no empty frame", gone && gone.framed === false,
     JSON.stringify(gone));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
