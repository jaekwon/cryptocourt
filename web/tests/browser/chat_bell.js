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

  /* THE BELL IS A RECORDING, AND THE SYNTHESIS IS ITS FALLBACK.
     Emmanuel of Notre-Dame, chosen by measurement rather than taste: twelve real
     bells were cut to ten seconds from the strike, and every one preferred had a
     spectral centroid at or under 1100Hz while every one rejected was 1580 or
     above — including one that rang LONGER than any keeper and was refused for
     being bright. Darkness, not resonance. Emmanuel measures 642.
     SHIPPED AS A FILE NEXT TO chat.js, so the source must be RELATIVE: an
     absolute URL would be the one thing the overlay may not do. */
  const bellSrc = await page.evaluate(() => typeof CHATBELLSRC === "string" ? CHATBELLSRC : null);
  ok(`the bell names a recording (${bellSrc})`,
     !!bellSrc && !/^https?:|^\/\//.test(bellSrc), String(bellSrc));

  /* THE FALLBACK IS NOT DECORATION, and this check runs on file:// where the
     fetch cannot succeed — so what is exercised here IS the fallback path. A
     deploy that forgets to ship bell.mp3 degrades to a worse bell rather than to
     silence, and silence is what would be reported as "the bell is broken". */
  const fell = await page.evaluate(async () => {
    window.__rings = 0;
    chatBell();
    await new Promise(r => setTimeout(r, 400));
    return window.__rings;
  });
  ok(`with no recording reachable it still rings, synthesised (${fell} oscillators)`,
     fell > 0, "the bell went silent instead of falling back");

  /* AND THE SYNTHESIS IS A BELL RATHER THAN A CHORD. Two properties do that, and
     both are readable from the mode table: the spectrum is INHARMONIC — the
     tierce at 1.2 is nowhere near a whole number, which is what a string or a
     pipe could never produce — and every mode is a DOUBLET, two oscillators a
     fraction of a hertz apart, whose beating is the warble. An earlier version
     set `detune` on a single oscillator per mode, which shifts its pitch and
     produces no beating at all, because beating needs something to beat
     against. */
  const modes = await page.evaluate(() => (typeof CHATBELLMODES !== "undefined") ? CHATBELLMODES : null);
  ok("the synthesis has a mode table", Array.isArray(modes) && modes.length >= 8,
     JSON.stringify(modes && modes.length));
  ok("...that is inharmonic, which is what makes it a bell",
     !!modes && modes.some(m => Math.abs(m[0] - Math.round(m[0])) > 0.05),
     JSON.stringify(modes && modes.map(m => m[0])));
  ok("...with a split per mode, so the doublets beat",
     !!modes && modes.every(m => m[3] > 0), JSON.stringify(modes && modes.map(m => m[3])));
  ok("...and one oscillator per side of every doublet",
     fell === (modes ? modes.length * 2 : -1), `${fell} started for ${modes && modes.length} modes`);
  ok("...whose high modes die before the hum does",
     !!modes && modes[0][2] > modes[modes.length - 1][2] * 5,
     JSON.stringify(modes && [modes[0][2], modes[modes.length - 1][2]]));

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
  const back = await page.evaluate(async () => {
    window.__rings = 0;
    document.querySelector('.chatbell').click();
    await new Promise(r => setTimeout(r, 400));
    return {rings: window.__rings, on: chatBellOn()};
  });
  ok("switching it back on rings once so the reader hears it",
     back.on === true && back.rings > 0, JSON.stringify(back));

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
