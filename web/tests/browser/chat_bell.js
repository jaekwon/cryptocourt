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

  /* THE MARK, AND ONLY THE MARK. A message that ENDS in an exclamation rings, as
     does "!?" or "?!" anywhere in it. An ordinary sentence, a bare question and
     a trailing-off thought do not — otherwise every message in a busy room is a
     summons.
     IT STARTED AT "!?" ONLY, and "Whoa!" was silent, which was reported straight
     back: plainly the same signal. TRAILING rather than anywhere, because
     "don't! stake on that" is an ordinary sentence with an exclamation buried in
     it and must stay quiet — that case is the whole reason this is anchored. */
  const re = (s) => page.evaluate(s => CHATBELLRE.test(s), s);
  for (const s of ["Whoa!", "whoa?!", "what!?", "look at this!", "!?",
                   "(Whoa!)", "Whoa!  "]) {
    ok(`"${s}" rings`, await re(s) === true);
  }
  for (const s of ["hello", "why?", "what is 2+2?", "??", "wait...",
                   "don't! stake on that"]) {
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
    if (!b) return null;
    const svg = b.querySelector('svg');
    const r = b.getBoundingClientRect();
    // getBBox is the union of what is actually PAINTED, in the viewBox's own
    // units — the one measurement that can tell a bell from an empty <svg>.
    const box = svg ? svg.getBBox() : null;
    const vb = svg ? (svg.getAttribute('viewBox') || '').split(/\s+/).map(Number) : null;
    return {
      on: b.getAttribute('aria-pressed'),
      text: (b.textContent || '').trim(),
      aria: b.getAttribute('aria-label') || '',
      w: Math.round(r.width), h: Math.round(r.height),
      svg: !!svg,
      paths: svg ? svg.querySelectorAll('path').length : 0,
      // every path must take its colour from the row rather than carry its own
      inherits: svg ? [...svg.querySelectorAll('path')].every(p => {
        const f = p.getAttribute('fill'), st = p.getAttribute('stroke');
        return (f === 'currentColor' || st === 'currentColor');
      }) : false,
      fill: box ? +(box.width / (vb[2] || 1)).toFixed(2) : 0,
      tall: box ? +(box.height / (vb[3] || 1)).toFixed(2) : 0,
      // the rendered glyph, in CSS pixels, against the row's own font size
      px: svg ? Math.round(svg.getBoundingClientRect().height) : 0,
      em: Math.round(parseFloat(getComputedStyle(b).fontSize)),
    };
  });
  ok("the panel offers a bell switch", !!bell, JSON.stringify(bell));
  ok(`...on by default (aria-pressed=${bell && bell.on})`, bell && bell.on === "true");

  /* A DRAWN BELL, AND THIS ARM HAS NOW BEEN WRONG TWICE — kept as a record
     rather than quietly rewritten a third time.
       FIRST it asserted the switch was labelled in WORDS, reasoning that an icon
     would need a font the overlay does not control.
       THEN that reasoning was called wrong for emoji specifically: 🔔 comes from
     the system's own emoji font, needs no embedded face, and is not the business
     of check-mark-font. All true, and it left out what a system font also
     decides — 🔔 is a gold three-dimensional cartoon on Apple, flat yellow on
     Android, a line drawing on Windows, and 🔕 adds a red stroke on some and not
     others. RENDERED SIDE BY SIDE against the rest of the panel, the emoji was
     the only thing on the row that did not look like it belonged to the page.
       NOW it is a path, which needs no font at all: not the emoji font, not the
     embedded hieroglyph face, not check-mark-font's business either.
     WHAT SURVIVED BOTH REVERSALS is the arm below it — the words live in
     aria-label, so none of this removed the switch from assistive technology.
     That one has never had to change and is the point of the pair. */
  ok("...shown as a drawn glyph rather than an emoji",
     !!(bell && bell.svg && !/[\u{1F514}\u{1F515}]/u.test(bell.text)), JSON.stringify(bell));
  /* AND IT IS A BELL, NOT AN EMPTY BOX. The comment-cluster work taught this the
     expensive way: a glyph too small or too faint to see passed every assertion
     that only asked whether the element existed. So what is measured is the
     PAINTED extent — a path whose ink fills two thirds of its own viewBox in
     both directions cannot be blank, clipped or collapsed. */
  ok(`...whose ink fills its viewBox (${bell && bell.fill} wide, ${bell && bell.tall} tall)`,
     !!(bell && bell.fill >= 0.6 && bell.tall >= 0.6), JSON.stringify(bell));
  /* ...AT THE SIZE OF THE TEXT BESIDE IT, because 1em is what makes it read as a
     glyph in the row rather than an image dropped into it. A generous band: what
     this rejects is the 0px collapse and the 3em intrusion, not a pixel of
     rounding. */
  ok(`...at about the row's own text size (${bell && bell.px}px against ${bell && bell.em}px)`,
     !!(bell && bell.px >= bell.em * 0.7 && bell.px <= bell.em * 1.6), JSON.stringify(bell));
  /* ...IN THE ROW'S OWN COLOUR. The panel is embedded in a page with four themes
     and has no access to its tokens, so a hardcoded fill would be wrong in at
     least one of them — the same reason .chatwarn is opacity and weight only. */
  ok("...taking its colour from the row rather than carrying its own",
     !!(bell && bell.inherits), JSON.stringify(bell));
  ok("...and still named in words for a screen reader",
     !!(bell && /bell/i.test(bell.aria || "")), JSON.stringify(bell && bell.aria));

  await page.evaluate(() => { window.__rings = 0; });
  await page.click('.chatbell');
  await new Promise(r => setTimeout(r, 400));
  const off = await page.evaluate(() => ({
    rang: window.__rings,
    pressed: document.querySelector('.chatbell').getAttribute('aria-pressed'),
    stored: (() => { try { return localStorage.getItem("kourt.chat.bell"); } catch (e) { return "?"; } })(),
    on: chatBellOn(),
    glyph: (document.querySelector('.chatbell').textContent || '').trim(),
    // the struck-through state is one more path than the ringing one
    paths: document.querySelectorAll('.chatbell svg path').length,
    strokes: [...document.querySelectorAll('.chatbell svg path')]
      .filter(p => p.getAttribute('stroke') === 'currentColor').length,
    dim: +getComputedStyle(document.querySelector('.chatbell')).opacity,
  }));
  ok("clicking it silences the bell", off.pressed === "false" && off.on === false,
     JSON.stringify(off));
  /* AND THAT CLICK SOUNDED. It used to ring only on the way ON, so a reader
     whose bell was already on — which is the default — had to click TWICE to
     hear anything, and reported exactly that. A bell you press should sound.
     Muting rings once as the cost of it: you hear what you are switching off. */
  ok(`...and pressing it sounds, even on the way off (${off.rang})`,
     off.rang > 0, JSON.stringify(off));
  /* AND THE GLYPH ITSELF CHANGES, which is the whole reason a glyph can replace
     the word: a bell with a stroke through it means off, and nothing else has to
     say so. The stroke is COUNTED rather than looked for by shape — one more
     path than the ringing state, and a stroked one, which is exactly what the
     "off" branch adds and nothing else in the glyph is. */
  ok(`...and the glyph gains a stroke through it (${off.paths} paths, ${off.strokes} stroked)`,
     off.paths === (bell.paths + 1) && off.strokes === 1, JSON.stringify(off));
  /* ...AND DIMS AS WELL, which is not redundancy. At 1em the slash is a pixel and
     a half wide; on a phone, at a glance, the difference in weight is what the
     reader actually notices first. Two signals for one state, deliberately. */
  ok(`...and dims (opacity ${off.dim})`, off.dim > 0 && off.dim < 0.75, JSON.stringify(off));
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
  /* YOUR OWN MARK RINGS TOO. This arm asserted the opposite — that the gate
     skipped your own messages, on the reasoning that you know what you just
     typed. True, and not the point: reported twice as "it still doesn't ring
     when I type what?!". Somebody ringing a bell on purpose wants to hear that
     it rang, and the suppression made a working bell look broken from the one
     seat that most needed the confirmation. Now asserted as an ABSENCE, so the
     old behaviour cannot creep back unnoticed. */
  ok("...and does not exclude your own messages", !/\bmine\b/.test(gate), gate.slice(0, 220));
  ok("...and only messages past the last id drawn",
     /m\.id > wasSeen/.test(gate), gate.slice(0, 200));

  /* A BACKGROUND TAB STILL HEARS IT PROMPTLY. The panel backs off when hidden,
     which is right — a court left open overnight must not poll like a watched
     one, and must not hold a socket either — but at the original sixty seconds
     the bell could arrive a full minute after the message that rang it, which is
     an echo rather than a notification. Pinned as a RANGE, not a number: the
     floor is what makes a background ring feel prompt, and the ceiling is what
     stops a hidden tab from polling like a foreground one. */
  const hidden = await page.evaluate(() =>
    typeof CHATHIDDENPOLL === "number" ? CHATHIDDENPOLL : null);
  ok(`a hidden tab re-reads often enough to ring promptly (${hidden}ms)`,
     hidden !== null && hidden <= 20000, String(hidden));
  ok("...but still slower than a watched one", hidden !== null && hidden >= 10000,
     String(hidden));

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
