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
// NOT SWEPT BELOW 800, AND THAT BOUND IS A SECOND OPEN BUG, not a tuning
// choice — recorded here because a height list with no stated reason is how a
// check quietly stops covering the thing it was written for.
// `.railchat` IS this panel (the rail's chat slot wears both classes) and it
// carries flex:1 1 auto with min-height:0 and overflow:hidden, so it can end up
// SHORTER than its own rows and clip them. Pinning the rows stopped them
// collapsing, which is the reported bug; it does not stop the container
// clipping them. Below the bound the composer is clipped and the rail's own
// foot — the node selector at 700, the theme button at 620 — is what the
// pointer reaches, and by 560 the row is outside the viewport entirely.
// A min-height:min-content floor on the panel was tried and MEASURED WORSE: it
// inflates the panel to full content height and pushes the foot to y=896 with
// the composer off-screen at every height tested. The real fix is in the rail's
// layout in index.html, which is not this file's to change and is currently
// open in another session; it is filed as its own task.
// The bound differs between the demo page and the deployed one — 800 here, 700
// live — because demo mode carries an extra node-selector block in the rail.
// The lower of the two is what this file sweeps.
const {PAGE, demoPage} = require('./harness');

const HEIGHTS = [1000, 900, 800];

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
      const centre = el => { const b = el.getBoundingClientRect();
        return at(b.left + b.width / 2, b.top + b.height / 2); };
      const N = nm.getBoundingClientRect(), F = form.getBoundingClientRect();
      return {name: centre(nm), send: centre(sd),
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
  }

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
