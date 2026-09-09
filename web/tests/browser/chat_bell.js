// THE BELL: it rings for a deliberate mark, and it can be switched off.
//
// Asked for as "make it sound a bell when someone says !?" — so the trigger is a
// thing a reader TYPES when they mean "look at this", rather than every arrival.
// A bell on every message is a bell nobody keeps switched on.
//
// WHY A BROWSER CHECK. The sound is synthesised — two oscillators through a gain
// envelope, because the overlay may not fetch an audio file — and none of that
// exists outside a document. AudioContext is stubbed here so a ring can be
// COUNTED rather than heard; the stub records what was started, which is the only
// observable a headless run has.
//
// WHAT THIS DOES NOT COVER, said plainly. The ring is wired into the poll's paint
// path and fires for messages past the last id drawn, skipping your own and the
// opening read of a room. Reproducing that needs a live service and a growing
// transcript, so those three conditions are asserted against the SOURCE below
// rather than by arrival. A future change that keeps the source shape and breaks
// the behaviour would pass here.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 950});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // Counting stub, installed before any script runs.
  await page.evaluateOnNewDocument(() => {
    window.__rings = 0;
    class FakeOsc {
      constructor() { this.frequency = {value: 0}; this.type = ""; }
      connect() {} start() { window.__rings++; } stop() {}
    }
    class FakeGain {
      constructor() { this.gain = {setValueAtTime() {}, exponentialRampToValueAtTime() {}}; }
      connect() {}
    }
    window.AudioContext = class {
      constructor() { this.state = "running"; this.currentTime = 0; this.destination = {}; }
      createOscillator() { return new FakeOsc(); }
      createGain() { return new FakeGain(); }
      resume() {}
    };
  });

  await page.goto(PAGE + '#/c/orem', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 1200));

  /* THE MARK, AND ONLY THE MARK. "!?" and "?!" ring; an ordinary sentence, an
     ordinary exclamation and a bare question do not — otherwise every message in
     a busy room is a summons. */
  const re = (s) => page.evaluate(s => CHATBELLRE.test(s), s);
  for (const s of ["look at this !?", "what?!", "!?", "is that right!?"]) {
    ok(`"${s}" rings`, await re(s) === true);
  }
  for (const s of ["hello", "really!", "why?", "what is 2+2?", "!!", "??"]) {
    ok(`"${s}" does not`, await re(s) === false);
  }

  /* THE SOUND IS SYNTHESISED, NOT FETCHED. The overlay's one promise is that it
     is self-contained; an audio file would break it for a two-note ding. Counted
     through the stub: two oscillators, which is the ding rather than a beep. */
  const rang = await page.evaluate(() => { window.__rings = 0; chatBell(); return window.__rings; });
  ok(`ringing starts the two notes of a ding (${rang})`, rang === 2, String(rang));

  /* AND A BLOCKED OR ABSENT AudioContext IS SILENT, NOT AN ERROR. A browser that
     refuses audio until the reader has clicked is the NORMAL case, not a fault:
     the first ring in a fresh tab may simply not sound. */
  const survived = await page.evaluate(() => {
    const real = window.AudioContext;
    window.AudioContext = undefined; window.webkitAudioContext = undefined;
    let threw = false;
    try { chatBell(); } catch (e) { threw = true; }
    window.AudioContext = real;
    return !threw;
  });
  ok("a browser with no audio at all is silent rather than broken", survived);

  /* THE SWITCH. Default on — a control nobody finds is a feature nobody has —
     and remembered, because a reader who silenced it did not mean "until the next
     page". */
  const bell = await page.evaluate(() => {
    const b = document.querySelector('.chatbell');
    return b ? {on: b.getAttribute('aria-pressed'), text: (b.textContent || '').trim(),
                w: Math.round(b.getBoundingClientRect().width)} : null;
  });
  ok("the panel offers a bell switch", !!bell, JSON.stringify(bell));
  ok(`...on by default (aria-pressed=${bell && bell.on})`, bell && bell.on === "true");
  ok(`...labelled in words rather than a glyph ("${bell && bell.text}")`,
     !!(bell && /[a-z]/i.test(bell.text)), JSON.stringify(bell));

  await page.click('.chatbell');
  await new Promise(r => setTimeout(r, 200));
  const off = await page.evaluate(() => ({
    pressed: document.querySelector('.chatbell').getAttribute('aria-pressed'),
    stored: (() => { try { return localStorage.getItem("kourt.chat.bell"); } catch (e) { return "?"; } })(),
    on: chatBellOn(),
  }));
  ok("clicking it silences the bell", off.pressed === "false" && off.on === false,
     JSON.stringify(off));
  ok("...and the choice is written down", off.stored === "0", JSON.stringify(off));

  /* SWITCHING IT BACK ON RINGS ONCE, which is not decoration: that click is also
     the gesture that unblocks audio in a fresh tab, so it is the one moment the
     reader can be shown what they just enabled. */
  const back = await page.evaluate(() => {
    window.__rings = 0;
    document.querySelector('.chatbell').click();
    return {rings: window.__rings, on: chatBellOn()};
  });
  ok("switching it back on rings once so the reader hears it", back.on === true && back.rings === 2,
     JSON.stringify(back));

  /* ---- the three conditions, read from the source ------------------------
     See the header: reproducing an arrival needs a live service. These assert
     the shape of the gate, and they are the weakest arms in this file. */
  const src = require('fs').readFileSync(
    require('path').join(__dirname, '..', '..', 'chat.js'), 'utf8');
  const gate = (src.match(/if \(!wasFirst && chatBellOn\(\)[\s\S]{0,400}?\n      \}/) || [""])[0];
  ok("the ring is gated on the poll's own arrival test", gate.length > 0,
     "no ring gate found in chat.js");
  ok("...it skips the opening read of a room", /!wasFirst/.test(gate), gate.slice(0, 120));
  ok("...it skips your own messages", /!mine\.has\(m\.id\)/.test(gate), gate.slice(0, 200));
  ok("...and only messages past the last id drawn",
     /m\.id > wasSeen/.test(gate), gate.slice(0, 200));

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
