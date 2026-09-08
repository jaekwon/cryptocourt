// The composer's buttons can be hit ON THEIR LETTERS, in a short window.
//
// WHY THIS EXISTS. A reader reported that the name chip and send took no click
// and showed no pointer when the cursor was directly over their letters, while
// the PADDING of the same buttons worked and every other button on the page
// worked. Four fixes were shipped from the wrong theory — user-select, a
// pointer-events:none label wrapper, cache headers, a service worker — because
// every measurement here was taken in a tall window, where none of it happens.
//
// THE ACTUAL CAUSE, once a probe reported what was under the reader's pointer
// rather than under mine: `div.chatnote`. In the rail the panel is a flex
// COLUMN and index.html's `.railchat > *` sets min-height:0 on every child,
// which removes the automatic minimum size that stops a flex item shrinking
// below its content. Every row still had flex-shrink:1, so a short viewport
// shrank them together instead of letting the log absorb it alone: at 700px the
// form collapsed to a 10px box while the 35px button inside it overflowed 25px
// below, and .chatnote — the panel's last child, therefore painted on top —
// took the hit over the letters. The button's top padding stayed inside the
// form's own box, which is why the padding kept working. Fixed by pinning
// .chathead/.chatstate/.chatform/.chatnote to flex:0 0 auto.
//
// WHY IT IS MEASURED THIS WAY. The bug was invisible to every check already in
// the tree for three separate reasons, and this file is built against all three:
//   - IT ONLY EXISTS IN A SHORT WINDOW. The existing chat checks run at one
//     tall viewport, so the form never got squeezed. Heights are swept here,
//     and 800 is the shortest one in the list for the reason recorded below.
// EVERY HEIGHT IS SWEPT, AND THE ASSERTION IS "NOT COVERED" rather than "on
// screen without scrolling". At 620px the composer sits below the rail's fold
// and the rail scrolls to it, which is a normal thing a sidebar does; the bug
// was a control that was VISIBLE and took no click. So each control is scrolled
// into view if it is outside the viewport and then hit-tested, and the failure
// is landing on some other element.
//
//   - IT IS A HIT TEST, NOT A COUNT. The button was present, enabled, correctly
//     classed, cursor:pointer in its own style, and 35px tall the whole time —
//     every countable property was right. What was wrong is which element the
//     pointer reaches, so elementFromPoint at the button's CENTRE is the
//     assertion, the point where the letters are.
//   - THE OVERFLOW IS THE MECHANISM. A geometry arm compares the button's box
//     to its form's, so a future rule that lets the row collapse again fails
//     here with the reason attached rather than as a bare missed click.
//
// ABLATED against a CONTROL run of the unmodified stylesheet, which fires
// nothing — without that control "4 arms fired" is not evidence, since a copy
// broken for its own reasons reports the same. Counts are what actually fired,
// and the second one contradicts what this comment first predicted:
//   - remove the pin entirely -> 4. Send reaches `div.chatnote` at 900 and
//     `div.foot` at 800, and both geometry arms trip there: a 25px row holding
//     a 35px button, hanging 9px below it. The first of those is the shipped
//     bug reproduced by name.
//   - pin .chatform ALONE, leaving .chatnote shrinking -> 0, not the 2 this
//     comment claimed before the run. Pinning the form is on its own enough to
//     satisfy every arm here. So the .chathead/.chatstate/.chatnote half of the
//     pin is INTENT — the log is the designated absorber and the fixed rows say
//     so — and it is NOT covered behaviour. Anyone narrowing it will not be
//     caught by this file, which is worth knowing before trusting it.
// Both mutations are applied to a COPY of chat.js outside the repo: a second
// session edits these files, and an in-place mutation has already been written
// back once from that session's stale buffer.
//
// SWEPT DOWN TO 620 NOW, and the bound used to be 800 because of a second bug
// that is fixed. `.railchat` IS this panel, and it carried flex:1 1 auto with
// min-height:0 and overflow:hidden, so the rail handed it LESS height than its
// own controls occupy and clipped them — 159px of panel around a 232px composer
// at 800px, with send's centre landing on a stray <b> from the block painted
// underneath. Pinning the rows stopped them collapsing; it did not stop the
// container clipping them.
//
// It surfaced here because a nav link was added for the parameters page: the
// rail's nav went from five entries to six, the threshold moved up from ~700 to
// 800, and this file went red 3/3 — which is how a 28px addition to a sidebar
// turned into a dead button. Worth keeping in mind about this layout.
//
// Fixed by flooring the panel at min-content and giving .chatlog height:0, so
// min-content resolves to the CONTROLS rather than the controls plus a
// screenful of messages. The log yields instead: 127px at 1000, 27px at 900, 0
// by 800. Two alternatives were measured and rejected — a bare min-content
// floor with the log sized by its messages put the composer off-screen at every
// height (floor 469px), and a min-height on the log made the rail scroll even
// at 1000px while never shrinking.
//
const {PAGE, demoPage} = require('./harness');

const HEIGHTS = [1000, 900, 800, 760, 700, 620];

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  for (const h of HEIGHTS) {
    await page.setViewport({width: 1280, height: h});
    await page.goto(PAGE + '#/c/orem', {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 900));

    const m = await page.evaluate(() => {
      const nm = document.querySelector('.chatnamebtn');
      const sd = document.querySelector('.chatsend');
      const form = document.querySelector('.chatform');
      if (!nm || !sd || !form) return {missing: true};
      // The name of whatever the pointer would actually reach at a point.
      const at = (x, y) => { const t = document.elementFromPoint(x, y);
        return t ? t.tagName.toLowerCase()
          + (typeof t.className === "string" && t.className.trim()
             ? "." + t.className.trim().split(/\s+/).join(".") : "") : "none"; };
      /* SCROLL IF IT IS OFF THE VIEWPORT, then hit-test — because "off the
         bottom" and "covered by something else" are different facts and only
         the second is the bug. elementFromPoint returns null for a point
         outside the viewport, so without this a control the reader can simply
         scroll to reads identically to one that is dead under another element.
         At 620px the composer IS below the fold, and that is acceptable: the
         rail scrolls. Being visible and unclickable is not. */
      const centre = el => { const b0 = el.getBoundingClientRect();
        const inView = b0.top >= 0 && b0.bottom <= innerHeight;
        if (!inView) el.scrollIntoView({block: "center"});
        const b = el.getBoundingClientRect();
        return at(b.left + b.width / 2, b.top + b.height / 2); };
      const N = nm.getBoundingClientRect(), F = form.getBoundingClientRect();
      // Was the composer already on screen BEFORE anything was scrolled? This
      // is what the log yielding buys, and centre() would hide it.
      const inViewUnscrolled = F.top >= 0 && F.bottom <= innerHeight;
      return {name: centre(nm), send: centre(sd), inViewUnscrolled,
              formH: Math.round(F.height), btnH: Math.round(N.height),
              // positive means the button hangs out below its own form
              overflow: Math.round(N.bottom - F.bottom)};
    });

    if (m.missing) { ok(`the composer mounts at ${h}px`, false); continue; }

    // THE ASSERTIONS THIS FILE IS FOR: the letters, not the padding.
    ok(`at ${h}px the name chip takes the pointer at its centre`,
       /\bchatnamebtn\b/.test(m.name), `reached ${m.name} instead`);
    ok(`at ${h}px send takes the pointer at its centre`,
       /\bchatsend\b/.test(m.send), `reached ${m.send} instead`);
    // The mechanism, so a regression says why rather than just failing.
    ok(`at ${h}px the button does not overflow its own row`,
       m.overflow <= 0, `button hangs ${m.overflow}px below the form`);
    ok(`at ${h}px the row is at least as tall as the button in it`,
       m.formH >= m.btnH, `form ${m.formH}px vs button ${m.btnH}px`);
    /* AND AT A COMFORTABLE HEIGHT IT NEEDS NO SCROLLING AT ALL. This is the arm
       that pins the log yielding: with the log sized by its messages instead of
       height:0, the panel's floor becomes the whole panel (469px measured) and
       the composer is pushed below the fold even in a tall window. Tolerating a
       scroll is right at 620px and wrong at 900 — a sidebar chat you must
       scroll to type in, in a full-height window, is the log winning an
       argument it should lose. Only the roomy heights, since below them the
       scroll is the intended behaviour. */
    if (h >= 900) {
      ok(`at ${h}px the composer needs no scrolling`, m.inViewUnscrolled,
         `form box was outside the viewport at ${h}px`);
    }
  }

  /* ── AND NARROW, WHERE THE RAIL IS NOT A SIDEBAR ────────────────────────────
     THE SWEEP ABOVE IS ALL AT WIDTH 1280, which is why it could not see this.
     Reported from a phone: "i can't see *any* chat there besides the input
     field." Measured at 390, 430 and 768 — the log's box was 0px tall with FOUR
     messages inside it and a scrollHeight of 194.
     BECAUSE THE FIX ABOVE ASSUMES A CONTAINER WITH HEIGHT TO GIVE AWAY. Below
     the layout's 820px breakpoint the rail is `position:static; height:auto`,
     so it sizes to its content and distributes no free space; the log's
     height:0 basis is then all it ever gets, and every message renders inside a
     zero-height box. The composer stayed visible, so the panel looked present
     and simply had nothing in it — the failure mode that gets reported as "chat
     doesn't work" rather than "chat is clipped".
     THE ARM IS THE ROW INSIDE THE LOG'S BOX, not the log's own height. A log
     with height and its messages scrolled out of sight is the same experience,
     and a height alone would pass on it. Rows are counted first: on a fixture
     with an empty room every one of these would certify nothing. */
  for (const w of [390, 430, 768]) {
    await page.setViewport({width: w, height: 844});
    await page.goto(PAGE + '#/c/orem', {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 900));
    const n = await page.evaluate(() => {
      const log = document.querySelector('.chatlog');
      const form = document.querySelector('.chatform');
      if (!log || !form) return {missing: true};
      const rows = [...log.querySelectorAll('.chatmsg')];
      const L = log.getBoundingClientRect();
      const last = rows.length ? rows[rows.length - 1].getBoundingClientRect() : null;
      const at = (x, y) => { const t = document.elementFromPoint(x, y);
        return t ? t.tagName.toLowerCase()
          + (typeof t.className === "string" && t.className.trim()
             ? "." + t.className.trim().split(/\s+/).join(".") : "") : "none"; };
      const centre = el => { const b0 = el.getBoundingClientRect();
        if (!(b0.top >= 0 && b0.bottom <= innerHeight)) el.scrollIntoView({block: "center"});
        const b = el.getBoundingClientRect();
        return at(b.left + b.width / 2, b.top + b.height / 2); };
      return {rows: rows.length, logH: Math.round(L.height),
              scrollH: log.scrollHeight,
              // how far the newest row falls outside the log's visible box
              spillTop: last ? Math.round(L.top - last.top) : null,
              spillBottom: last ? Math.round(last.bottom - L.bottom) : null,
              send: centre(document.querySelector('.chatsend'))};
    });
    if (n.missing) { ok(`the chat panel mounts at ${w}px wide`, false); continue; }
    ok(`the ${w}px fixture has messages to show`, n.rows > 0,
       "an empty room would make the arms below vacuous");
    ok(`at ${w}px wide the log has height (${n.logH}px for ${n.rows} rows)`,
       n.logH > 20, `log box was ${n.logH}px tall around ${n.scrollH}px of messages`);
    ok(`...and the newest message is inside the log's box, not clipped out of it`,
       n.rows > 0 && n.spillTop <= 1 && n.spillBottom <= 1,
       `row spills ${n.spillTop}px above / ${n.spillBottom}px below the log`);
    // The composer must still take its own clicks here: this is the layout the
    // height:0 rule was protecting, and the narrow case must not buy the log
    // back by re-clipping the controls.
    ok(`...and send still takes the pointer at ${w}px wide`,
       /\bchatsend\b/.test(n.send), `reached ${n.send} instead`);
  }

  /* ── ONE CLICK GIVES THE CHAT THE RAIL ──────────────────────────────────────
     Asked for: "make the left sidebar chat expandable in case your browser
     height is short on desktop. one click... and squishes or overrides lines
     above chat like REFERENCE".
     THE SHORT WINDOW IS THE POINT, so 700 is measured and not just 1000. At
     1280x700 the log is 0px before the click — the default trade this file's
     first half exists to defend, where the composer keeps its floor and the log
     is what yields. Expanding is the reader taking that trade back for as long
     as they are talking.
     FOUR CLAIMS PER SIZE, and each is a different way for this to be broken: the
     log grows, the links above it actually fold (a log that grew while the nav
     stayed would mean the rail simply scrolls, which is not what was asked),
     the composer still takes its own clicks, and COLLAPSE PUTS EVERYTHING BACK
     — a one-way expand is a layout the reader cannot undo. Restoration is
     asserted as equality with the pre-click measurement rather than as "smaller
     than expanded", which a half-restore would also satisfy. */
  for (const h of [700, 1000]) {
    await page.setViewport({width: 1280, height: h});
    await page.goto(PAGE + '#/c/orem', {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 900));
    const read = () => page.evaluate(() => {
      const log = document.querySelector('#railchat .chatlog');
      const link = [...document.querySelectorAll('.nav a')]
        .find(a => /How it works/.test(a.textContent));
      const send = document.querySelector('.chatsend');
      const hgt = e => e ? Math.round(e.getBoundingClientRect().height) : null;
      let at = "none";
      if (send) { const r = send.getBoundingClientRect();
        const t = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        at = t && typeof t.className === "string" ? t.className : (t ? t.tagName : "none"); }
      const btn = document.getElementById('chatbig');
      return {log: hgt(log), nav: hgt(link), send: at,
              label: btn ? btn.textContent.trim() : null,
              expanded: btn ? btn.getAttribute('aria-expanded') : null};
    });
    const click = async () => { await page.evaluate(() => document.getElementById('chatbig').click());
                                await new Promise(r => setTimeout(r, 350)); };
    const before = await read();
    await click();
    const open = await read();
    await click();
    const shut = await read();

    ok(`at ${h}px the toggle says what it will do (${before.label}/${open.label})`,
       before.label === "expand" && open.label === "collapse" &&
       before.expanded === "false" && open.expanded === "true",
       JSON.stringify([before.label, open.label, before.expanded, open.expanded]));
    ok(`at ${h}px expanding grows the log (${before.log}px -> ${open.log}px)`,
       open.log >= before.log + 100, `only ${open.log - before.log}px more`);
    ok(`...by folding away the links above it (nav row ${before.nav}px -> ${open.nav}px)`,
       before.nav > 0 && open.nav === 0,
       "a log that grew while the nav stayed means the rail just scrolls");
    ok(`...and send still takes the pointer while expanded`,
       /\bchatsend\b/.test(open.send), `reached ${open.send} instead`);
    ok(`...and collapsing puts both back exactly (${shut.log}px log, ${shut.nav}px nav)`,
       shut.log === before.log && shut.nav === before.nav,
       `expected ${before.log}/${before.nav}`);
    /* THE 15rem CAP COMES OFF, and only a tall window can say so: at 700 the
       freed height is under the cap, so the arm above passes either way. At
       1000 there is 453px of room and chat.js's max-height would stop the log
       at 240 — which is how much of this button's effect the cap would eat. */
    if (h === 1000) {
      ok(`at ${h}px the log passes chat.js's 15rem cap (${open.log}px)`,
         open.log > 260, "the panel's page cap is still limiting the rail");
    }
  }
  /* AND THE TOGGLE IS NOT OFFERED WHERE IT WOULD TRAP A READER. Below the
     layout's breakpoint the rail is height:auto — nothing to expand into — so
     the button is hidden, and the remembered flag must be INERT rather than
     folding a phone's nav away with no visible control to bring it back. */
  {
    await page.setViewport({width: 390, height: 844});
    await page.goto(PAGE + '#/c/orem', {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 900));
    const m = await page.evaluate(() => {
      const btn = document.getElementById('chatbig');
      const link = [...document.querySelectorAll('.nav a')]
        .find(a => /How it works/.test(a.textContent));
      const log = document.querySelector('#railchat .chatlog');
      const hgt = e => e ? Math.round(e.getBoundingClientRect().height) : null;
      const shown = btn ? getComputedStyle(btn).display : "absent";
      const was = {log: hgt(log), nav: hgt(link)};
      if (btn) btn.click();
      return {shown, was, now: {log: hgt(log), nav: hgt(link)}};
    });
    ok("on a phone the expand toggle is not offered", m.shown === "none", m.shown);
    ok("...and setting it anyway changes nothing there",
       m.now.log === m.was.log && m.now.nav === m.was.nav,
       JSON.stringify(m));
  }

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
