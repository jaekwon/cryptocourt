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
    await page.goto(PAGE + '#/c/orem/chat', {waitUntil: 'domcontentloaded'});
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
    await page.goto(PAGE + '#/c/orem/chat', {waitUntil: 'domcontentloaded'});
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

  /* ── THE EXPAND TOGGLE WAS TESTED HERE, AND IT IS GONE ──────────────────
     About a hundred and twenty lines proved it worked: the log grew, the links
     above it folded, the node controls folded with them, the expanded log took
     most of the rail at 700 and at 1000, the way home stayed clickable, and a
     phone was never offered the button at all. All of it passed.
     IT WENT WITH THE SIDEBAR PANEL IT RESIZED. "it's probably a bad idea to have
     chat in the sidebar to begin with" — so there is no column to expand into
     and no nav to fold away; the chat has the page. The arms that survived the
     move are the ones about the panel itself, which are below and now measured
     on its own view: that it mounts and can be typed into at every width, that
     the keyboard reaches all of it, and that a phone gets targets a thumb can
     hit without the browser zooming.
     WHAT IS NOT COVERED ANY MORE, said plainly: nothing checks that the chat can
     be made bigger, because nothing can — the view is as big as the viewport
     allows and there is no second size to reach. */

  /* ---- THE SEAM IS NOT A CONTROL ANY MORE ---------------------------------
     THERE WAS A DRAG HANDLE, and roughly two hundred lines here proved it
     worked: a dotted grip drawn at rest, a keyboard separator, a clamp at each
     end, a reset that appeared only once a size was set, and a check that no
     nav item painted under it. All of it passed. It is gone anyway.
     WHY, in the owner's words: "when i drag it down lower past 'Realm
     parameters' ... instead of the top of the chat getting dragged downward, the
     chat div drags upward from the bottom", and then "the whole ...... drag
     thing is confusing" and "it's hard to even explain how to fix issues with
     it". That last sentence is the one that settled it. Three fixes had already
     landed against this control — a jump on first grab, a re-pin at the clamp, a
     sticky handle scrolling out of its own scroller — and a fourth symptom was
     still arriving. A control whose failures cannot be described is not a
     control anybody can reason about.
     WHAT REPLACED IT IS NOT A CONTROL AT ALL. The log has a floor and the links
     yield by scrolling, so the panel is usable without anybody arranging it.
     MEASURED, and this is why the handle had felt necessary: before the floor,
     the log was 0px tall at 1440 wide on every desktop height tested — 900, 800
     and 700 — because the nav's links take 333px and the panel's own controls
     take the rest. The drag was not a convenience on top of a working layout, it
     WAS the layout. At 700 the original could not even reach the composer.
     SO THESE ARMS MEASURE THE FLOOR AND THE ABSENCE OF THE HANDLE, and the
     expand toggle keeps its own section above — one button, two states, which is
     the whole of the sizing story now. */
  {
    /* NO AFFORDANCE LEFT, checked as the four things that made the row look
       draggable. Any one of them surviving is a row that still invites a pull
       and no longer answers one. */
    await page.setViewport({width: 1280, height: 900});
    await page.goto(PAGE + '#/c/orem/chat', {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 1000));
    const seam = await page.evaluate(() => {
      const g = document.getElementById('railchathead');
      if (!g) return null;
      const before = getComputedStyle(g, '::before');
      return {
        cursor: getComputedStyle(g).cursor,
        touch: getComputedStyle(g).touchAction,
        role: g.getAttribute('role'),
        tab: g.getAttribute('tabindex'),
        dots: before.borderTopStyle,
        dotsWidth: Math.round(parseFloat(before.width) || 0),
        reset: !!document.getElementById('chatauto'),
        title: g.getAttribute('title') || '',
      };
    });
    ok("the chat heading is a heading, not a resize handle",
       seam && seam.cursor !== 'ns-resize' && seam.touch !== 'none', JSON.stringify(seam));
    ok("...with no separator role or tab stop on it",
       seam && !seam.role && seam.tab === null, JSON.stringify(seam));
    ok(`...and no grip drawn above it (${seam && seam.dots}, ${seam && seam.dotsWidth}px)`,
       seam && (seam.dots === 'none' || seam.dotsWidth === 0), JSON.stringify(seam));
    ok("...and nothing telling the reader to drag it",
       seam && !/drag/i.test(seam.title), JSON.stringify(seam && seam.title));
    /* AND NO RESET, because there is nothing to reset from. It existed only to
       undo a drag, and a control that undoes a control nobody can perform is one
       more thing in a 230px column to ignore. */
    ok("...and no reset button beside it", seam && seam.reset === false,
       JSON.stringify(seam));
  }

  {
    /* THE FLOOR, AT EVERY HEIGHT THE RAIL IS LIKELY TO HAVE. This is the arm
       that would have failed before the change, at every one of these sizes,
       with log = 0.
       AND THE COMPOSER WITH IT, which is the harder half: giving the log a
       floor by pushing the panel past the bottom of the rail would satisfy the
       first check and leave nobody able to type. The original layout did exactly
       that at 700 — measured, composer off screen — so both are asserted
       together at each size rather than once at a convenient one. */
    for (const h of [1000, 900, 800, 700]) {
      await page.setViewport({width: 1280, height: h});
      await page.goto(PAGE + '#/c/orem/chat', {waitUntil: 'domcontentloaded'});
      // A HASH CHANGE IS NOT A RELOAD: the expanded class survives one, so the
      // state is cleared and the document reloaded before measuring. Measured as
      // alternating rows of nonsense when this was left out.
      await page.evaluate(() => {
        try { localStorage.removeItem("cc.chatbig"); } catch (e) {}
      });
      await page.reload({waitUntil: 'networkidle0'});
      await new Promise(r => setTimeout(r, 900));
      const m = await page.evaluate(() => {
        const q = s => document.querySelector(s);
        const box = s => { const e = q(s); return e ? e.getBoundingClientRect() : null; };
        const log = box('#chatview .chatlog'), form = box('#chatview .chatform');
        const nav = q('.rail .nav');
        return {
          log: log ? Math.round(log.height) : 0,
          composer: !!(form && form.height > 0 && form.bottom <= window.innerHeight + 1
                       && form.top >= -1),
          navScrolls: nav ? nav.scrollHeight > nav.clientHeight + 2 : false,
          nav: nav ? Math.round(nav.getBoundingClientRect().height) : 0,
        };
      });
      ok(`at ${h}px the log has room without anybody arranging it (${m.log}px)`,
         m.log >= 100, JSON.stringify(m));
      ok(`...and the composer is on screen at ${h}px`, m.composer === true,
         JSON.stringify(m));
    }
  }

  {
    /* AND THE FLOOR YIELDS WHEN THERE IS NO ROOM FOR IT, which is the half a
       floor invites you to forget. The rail spends 306px on furniture before
       either the links or the panel get anything — the mark, the Chat row, the
       node controls — so on a short-but-wide window a 120px log pushes the
       composer below the fold. MEASURED: it fits at 560 with nothing spare,
       hangs 3px under at 540 and 63px under at 480.
       SO THE FLOOR IS GUARDED ON HEIGHT and simply does not apply below 560.
       Asserted from both sides: floored where there is room, absent where there
       is not, and the composer on screen in both. Deleting the height guard
       fails the second pair; deleting the floor fails the first. */
    for (const [h, floored] of [[600, true], [480, false]]) {
      await page.setViewport({width: 1280, height: h});
      await page.goto(PAGE + '#/c/orem/chat', {waitUntil: 'domcontentloaded'});
      await page.evaluate(() => { try { localStorage.removeItem("cc.chatbig"); } catch (e) {} });
      await page.reload({waitUntil: 'networkidle0'});
      await new Promise(r => setTimeout(r, 800));
      const m = await page.evaluate(() => {
        const q = s => document.querySelector(s);
        const b = s => { const e = q(s); return e ? e.getBoundingClientRect() : null; };
        const f = b('#chatview .chatform');
        return {
          log: Math.round((b('#chatview .chatlog') || {height: 0}).height),
          composer: !!(f && f.height > 0 && f.bottom <= window.innerHeight + 1 && f.top >= -1),
        };
      });
      ok(`at ${h}px the log is ${floored ? "floored" : "allowed to yield"} (${m.log}px)`,
         floored ? m.log >= 100 : m.log < 100, JSON.stringify({h, ...m}));
      ok(`...and the composer is on screen either way at ${h}px`,
         m.composer === true, JSON.stringify({h, ...m}));
    }
  }

  {
    /* THE LINKS KEEP THEIR HEIGHT NOW, which is the plainest measure of what
       moving the chat bought. This arm used to require the opposite: the nav had
       to be a scroll container, because that was the only way the panel beneath
       it could have a usable height — MEASURED at 1440x900, the links were
       crushed to 28px of a scrolling window so the transcript could have 120.
       With the room on its own page the column holds only links again, so the
       assertion inverts: the nav is NOT a scroller and every link is simply
       there. A regression to overflow-y:auto here would mean something had
       started competing with the navigation again. */
    await page.setViewport({width: 1280, height: 800});
    await page.goto(PAGE + '#/c/orem', {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 900));
    const nav = await page.evaluate(() => {
      const n = document.querySelector('.rail .nav');
      const links = n ? [...n.querySelectorAll('a')] : [];
      return {
        overflowY: n ? getComputedStyle(n).overflowY : null,
        scrolls: n ? n.scrollHeight > n.clientHeight + 2 : null,
        height: n ? Math.round(n.getBoundingClientRect().height) : 0,
        allVisible: links.length > 3
          && links.every(a => a.getBoundingClientRect().height > 0),
      };
    });
    ok(`the links are not a scroller any more (${nav.overflowY}, ${nav.height}px)`,
       nav.overflowY !== 'auto' && nav.scrolls === false, JSON.stringify(nav));
    ok("...and every one of them is on screen", nav.allVisible === true,
       JSON.stringify(nav));

    /* NOTHING IS REMEMBERED ABOUT A SIZE, which is the last trace of the old
       control: a stale height in storage that no longer has a rule to feed. */
    const stored = await page.evaluate(() => {
      try { return localStorage.getItem("cc.chath"); } catch (e) { return "?"; }
    });
    ok("and no chat height is stored any more", stored === null || stored === "",
       JSON.stringify(stored));
  }

  /* ---- THE KEYBOARD CONTRACT ----------------------------------------------
     WHY THIS BLOCK EXISTS NOW. The seam used to be a keyboard-operable
     separator — role, tabindex, arrow keys — and removing the drag took that
     with it. What it did is gone for good and should be; what MUST still be true
     is that everything left in the panel can be reached and used without a
     pointer, and none of that was asserted anywhere.
     AND ENTER TO SEND WAS NOT TESTED AT ALL, which is the one worth having:
     chat.js handles Enter explicitly only in the NAME field, so the message box
     relies on native form submission. That is the right way to do it and it is
     exactly the kind of thing a later refactor breaks silently — chat_live's own
     post arm dispatches a synthetic submit event, so it proves the handler runs
     and says nothing about the key that reaches it. */
  {
    await page.setViewport({width: 1440, height: 900});
    await page.goto(PAGE + '#/c/orem/chat', {waitUntil: 'networkidle0'});
    await new Promise(r => setTimeout(r, 1100));

    /* EVERY CONTROL REACHABLE, IN A SENSIBLE ORDER. Read from the document
       rather than by pressing Tab 40 times: the order a browser walks is
       document order for anything without a positive tabindex, and asserting
       that nothing in here carries one is the same guarantee with a clearer
       failure. */
    const reach = await page.evaluate(() => {
      /* THE PANEL IS THE SCOPE. This used to include the rail's heading, because
         the panel hung beneath it and the two were one control surface. The chat
         is a view of its own now: the rail holds a link, which the page's own
         navigation covers, and what this block is about is whether the ROOM can
         be used without a pointer. */
      const panel = document.getElementById('chatview');
      const scope = [panel].filter(Boolean);
      const all = [...document.querySelectorAll(
        'a[href],button:not([disabled]),input,select,textarea,[tabindex]:not([tabindex="-1"])')]
        .filter(e => { const b = e.getBoundingClientRect(); return b.width > 0 && b.height > 0; })
        .filter(e => scope.some(s => s.contains(e)));
      return {
        classes: all.map(e => (e.className || '').split(' ')[0] || e.id),
        positiveTabindex: all.filter(e => +(e.getAttribute('tabindex') || 0) > 0).length,
        inputBeforeSend: all.findIndex(e => e.classList.contains('chatinput'))
                       < all.findIndex(e => e.classList.contains('chatsend')),
      };
    });
    for (const want of ['chatinput', 'chatsend', 'chatnamebtn', 'chatbell']) {
      ok(`the keyboard can reach .${want}`, reach.classes.includes(want),
         JSON.stringify(reach.classes));
    }
    ok("...and reaches the box before the button it feeds",
       reach.inputBeforeSend === true, JSON.stringify(reach.classes));
    /* NO POSITIVE TABINDEX ANYWHERE. One of those reorders the whole document's
       tab sequence around this panel, which is a page-wide defect introduced
       from inside a sidebar. */
    ok("...without any control jumping the queue with a positive tabindex",
       reach.positiveTabindex === 0, String(reach.positiveTabindex));

    /* AND FOCUS IS VISIBLE ON EACH, because a control you can reach and cannot
       see yourself on is not keyboard-operable, it is a guess. Custom-styled
       dark controls lose this constantly — the usual cause is a blanket
       outline:none. */
    const seen = await page.evaluate(() => {
      const out = {};
      for (const sel of ['.chatbell', '.chatnamebtn', '.chatinput', '.chatsend', '.chatwarnx']) {
        const e = document.querySelector('#chatview ' + sel) || document.querySelector(sel);
        if (!e) { out[sel] = null; continue; }
        e.focus();
        const cs = getComputedStyle(e);
        out[sel] = (cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0)
                 || cs.boxShadow !== 'none';
      }
      return out;
    });
    const invisible = Object.entries(seen).filter(([, v]) => v === false).map(([k]) => k);
    ok(`every control shows where the focus is (${Object.keys(seen).length} checked)`,
       invisible.length === 0, "no focus indicator on: " + invisible.join(", "));

    /* ENTER SENDS. Against a stubbed service rather than a real one, for the
       reason chat_here gives: a live kourtchat here would be a database and a
       port, and what is being measured is that the key reaches the submit path
       and the box is cleared afterwards. */
    const typed = await page.evaluate(async () => {
      window.__sent = [];
      const real = window.fetch;
      window.fetch = async (u, o) => {
        const s = String(u);
        if (o && o.method === 'POST' && /\/api\/chat\//.test(s)) {
          window.__sent.push(JSON.parse(o.body || '{}'));
          return new Response(JSON.stringify({ok: true, id: 1}),
            {status: 200, headers: {'Content-Type': 'application/json'}});
        }
        if (/\/api\/chat\/health/.test(s)) {
          return new Response(JSON.stringify({ok: true, enforcing: true}),
            {status: 200, headers: {'Content-Type': 'application/json'}});
        }
        if (/\/api\/chat\//.test(s)) {
          return new Response(JSON.stringify({messages: [], next: 1, you: {state: 'ok'},
            now: Math.floor(Date.now() / 1000), here: 1}),
            {status: 200, headers: {'Content-Type': 'application/json'}});
        }
        return real(u, o);
      };
      CFG.mode = 'live'; CFG.chat = 'http://chat.invalid';
      location.hash = '#/';
      await new Promise(r => setTimeout(r, 250));
      location.hash = '#/c/orem/chat';
      await new Promise(r => setTimeout(r, 1400));
      return !!document.querySelector('#chatview .chatinput');
    });
    ok("a live panel is mounted to type into", typed === true);

    // EMPTY FIRST: Enter on an empty box must not post, or every stray keypress
    // in the room is a blank message.
    await page.click('#chatview .chatinput');
    await page.keyboard.press('Enter');
    await new Promise(r => setTimeout(r, 500));
    const blank = await page.evaluate(() => window.__sent.length);
    ok("Enter on an empty box sends nothing", blank === 0, String(blank));

    await page.keyboard.type('sent with the enter key');
    await page.keyboard.press('Enter');
    await new Promise(r => setTimeout(r, 700));
    const after = await page.evaluate(() => ({
      sent: window.__sent, left: document.querySelector('#chatview .chatinput').value}));
    ok(`Enter in the message box sends it (${JSON.stringify((after.sent[0] || {}).body)})`,
       after.sent.length === 1 && after.sent[0].body === 'sent with the enter key',
       JSON.stringify(after.sent));
    ok("...and clears the box", after.left === "", JSON.stringify(after.left));
  }

  /* ---- THE RAIL'S LINE, WHICH IS ALL THAT IS LEFT IN THE COLUMN ------------
     ASKED FOR IN THESE TERMS: "when collapsed, instead of showing the chat text,
     show (how many people, how many recent messages) only, and in order to chat,
     the chat bar must be expanded", and "when there has been recent activity
     would be good to show for all users even if the chat is collapsed, like a
     bubble notification or something". Then the panel left the sidebar
     altogether, which makes the collapsed state the whole of what the rail does
     and "expanded" a page.
     A STUBBED SERVICE, so the counts are chosen rather than waited for. What is
     being measured is the arithmetic and the wording, not the network. */
  {
    const p = await browser.newPage();
    p.on('pageerror', e => errs.push(String(e.message || e)));
    await p.evaluateOnNewDocument(() => {
      window.__here = 1; window.__msgs = [];
      const real = window.fetch;
      window.fetch = async (u, o) => {
        const s = String(u);
        if (/\/api\/chat\/health/.test(s)) {
          return new Response(JSON.stringify({ok: true, enforcing: true}),
            {status: 200, headers: {'Content-Type': 'application/json'}});
        }
        if (/\/api\/chat\//.test(s)) {
          return new Response(JSON.stringify({
            messages: window.__msgs, next: 99, you: {state: 'ok'},
            now: Math.floor(Date.now() / 1000), here: window.__here,
          }), {status: 200, headers: {'Content-Type': 'application/json'}});
        }
        return real(u, o);
      };
    });
    const line = async () => p.evaluate(() => {
      const rh = document.getElementById('railchathead');
      const a = rh ? rh.querySelector('a.railchatlink') : null;
      return {text: rh ? (rh.innerText || '').replace(/\s+/g, ' ').trim() : null,
              href: a ? a.getAttribute('href') : null,
              dot: !!(rh && rh.querySelector('.railchatdot'))};
    });
    const setRoom = async (here, msgs) => {
      await p.evaluate((h, m) => { window.__here = h; window.__msgs = m; }, here, msgs);
    };
    const now = Math.floor(Date.now() / 1000);
    await p.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
    await p.evaluate(() => { CFG.mode = 'live'; CFG.chat = 'http://chat.invalid';
      try { localStorage.clear(); } catch (e) {} });

    /* QUIET IS A WORD, NOT A ZERO. "0 here · 0 recent" is three numbers saying
       nothing happened; a room with nobody in it is quiet. */
    await setRoom(1, []);
    await p.evaluate(() => { location.hash = '#/c/orem'; });
    await new Promise(r => setTimeout(r, 1500));
    let l = await line();
    ok(`an empty room reads as quiet (${JSON.stringify(l.text)})`,
       /quiet/i.test(l.text || ''), JSON.stringify(l));
    ok("...and still links to the room", l.href === '#/c/orem/chat', JSON.stringify(l));
    /* ONE PERSON IS THE READER. "1 here" counts whoever is looking at it, which
       is noise; two is the first number that says anything about the room. */
    ok("...and does not announce the reader to themselves",
       !/1 here/.test(l.text || ''), JSON.stringify(l));

    // People and messages, both counted.
    await setRoom(4, [{id: 1, moniker: 'a', body: 'x', created_at: now - 60},
                      {id: 2, moniker: 'b', body: 'y', created_at: now - 30}]);
    await new Promise(r => setTimeout(r, 22000));   // past RAILCHAT_MS
    l = await line();
    ok(`a busy room says how many people and how many messages (${JSON.stringify(l.text)})`,
       /4 here/.test(l.text || '') && /2 recent/.test(l.text || ''), JSON.stringify(l));
    /* AND THE DOT, which is the notification. RECENT AND UNSEEN, both — and this
       arm is what settled that: the first cut showed no dot until the room had
       been opened once, so a first-time reader saw nothing however busy it was.
       "when there has been recent activity would be good to show for all users"
       is the ask, and a reader who has never been in the room is one of them. */
    ok("...with a dot, because it is busy and this reader has not been in",
       l.dot === true, JSON.stringify(l));

    /* OPENING THE ROOM CLEARS IT, and that is the whole contract of a badge. */
    await p.evaluate(() => { location.hash = '#/c/orem/chat'; });
    await new Promise(r => setTimeout(r, 2000));
    await p.evaluate(() => { location.hash = '#/c/orem'; });
    await new Promise(r => setTimeout(r, 1800));
    l = await line();
    ok(`opening the room clears the dot (${JSON.stringify(l.text)})`,
       l.dot === false, JSON.stringify(l));
    /* ...WITHOUT CLEARING THE COUNTS. The messages are still recent; what
       changed is that this reader has seen them. A badge that took the counts
       with it would make the line say the room had gone quiet. */
    ok("...and the counts stay, because the room did not empty",
       /4 here/.test(l.text || '') && /2 recent/.test(l.text || ''), JSON.stringify(l));

    /* AND A NEWER MESSAGE BRINGS IT BACK. Without this the arm above passes on a
       dot that was simply deleted. */
    await setRoom(4, [{id: 1, moniker: 'a', body: 'x', created_at: now - 60},
                      {id: 2, moniker: 'b', body: 'y', created_at: now - 30},
                      {id: 3, moniker: 'c', body: 'z', created_at: now - 5}]);
    await new Promise(r => setTimeout(r, 22000));
    l = await line();
    ok(`a message after that brings the dot back (${JSON.stringify(l.text)})`,
       l.dot === true, JSON.stringify(l));
    await p.close();
  }

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
