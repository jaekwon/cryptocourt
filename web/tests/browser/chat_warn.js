// THE PANEL'S ONE ANTI-SCAM NOTICE: loud enough to read, and possible to put away.
//
// WHY IT IS LOUD. "names are unverified — nobody here is staff, and nobody can
// move funds for you" is the only thing standing between a reader and somebody
// calling themselves a moderator, and §6 measured what a plausible name is worth
// to a lure: the same message from "kourt-moderator" reads as legitimate and
// from "dave" reads as a scam. The notice was drawn at .85em and 60% opacity —
// dimmer than the court slug beside it, which is decoration. A notice nobody can
// see has not been given.
//
// WHY IT IS DISMISSABLE. It sits above a transcript that gets zero pixels in a
// short rail, so a reader who has already read it is paying for it with the only
// thing they came for.
//
// WHY A BROWSER CHECK. The dismissal is a click, a `hidden`, and a localStorage
// write that has to survive a reload — none of which exists until a document
// does. And the brightness is a COMPUTED style: chat.js injects its stylesheet
// into a page with four themes and its own overrides, so what the source says
// and what a reader sees are two different questions.
//
// MEASURED BY BREAKING IT, five ways, each failing only what it should:
//   opacity back to .6/.85em   the opacity AND weight arms fail
//   the button removed         the control arm fails, and its size arm reads 0x0
//   hiding the button, not the span   both dismissal arms fail: the sentence is
//                              still on screen with no way left to remove it
//   the hit target shrunk      the size arm fails at 8x12
//   the localStorage write cut the persistence arm fails — but only AFTER that
//                              arm was fixed. It first re-ran open(), which
//                              navigates to the URL the page is already on, hash
//                              and all, so the browser never rebuilt the
//                              document and the hidden span survived in the DOM.
//                              The arm passed with the write deleted. reload()
//                              is what makes the storage read run again.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  const slug = await (async () => {
    await page.goto(PAGE + '#/', {waitUntil: 'networkidle2'});
    await new Promise(r => setTimeout(r, 800));
    return page.evaluate(() => [...document.querySelectorAll('a[href^="#/c/"]')]
      .map(x => x.getAttribute('href'))
      .map(h => (h.match(/^#\/c\/([a-z0-9-]+)$/) || [])[1]).find(Boolean) || null);
  })();
  ok("the directory offers a court to open", !!slug, slug || "none");
  if (!slug) { await browser.close(); process.exit(1); }

  const settle = async () => {
    for (let i = 0; i < 20; i++) {
      if (await page.evaluate(() => !!document.querySelector('.chatpanel'))) break;
      await new Promise(r => setTimeout(r, 300));
    }
    await new Promise(r => setTimeout(r, 1200));
  };
  const open = async () => {
    await page.goto(PAGE + '#/c/' + slug, {waitUntil: 'networkidle2'});
    await settle();
  };
  /* A REAL RELOAD, AND IT HAS TO BE ONE. The persistence arm below first re-ran
     open(), which navigates to the URL the page is ALREADY on — hash and all —
     so the browser treated it as a same-document navigation and never rebuilt
     the document. The hidden span simply survived in the DOM, and the arm passed
     with the localStorage write deleted: measured, and it is the whole reason
     that arm exists. reload() fetches the document again, which is the only
     thing that makes the storage read run a second time. */
  const reopen = async () => {
    await page.reload({waitUntil: 'networkidle2'});
    await settle();
  };
  const look = () => page.evaluate(() => {
    const w = document.querySelector('.chatwarn');
    const slugEl = document.querySelector('.chatslug');
    if (!w) return {none: true};
    const cs = getComputedStyle(w);
    const r = w.getBoundingClientRect();
    const x = w.querySelector('.chatwarnx');
    const xr = x ? x.getBoundingClientRect() : null;
    return {
      text: (w.textContent || '').replace(/\s+/g, ' ').trim(),
      hidden: w.hidden, onScreen: r.width > 2 && r.height > 2,
      opacity: +cs.opacity, weight: cs.fontWeight,
      slugOpacity: slugEl ? +getComputedStyle(slugEl).opacity : null,
      hasX: !!x, xw: xr ? Math.round(xr.width) : 0, xh: xr ? Math.round(xr.height) : 0,
    };
  });

  await open();
  const a = await look();
  ok("the warning is on the page", !a.none && a.onScreen && !a.hidden, JSON.stringify(a));
  ok("...and still says both halves of it",
     /names are unverified/.test(a.text) && /nobody here is staff/.test(a.text)
     && /nobody can move funds for you/.test(a.text), JSON.stringify(a.text));
  /* BRIGHT, MEASURED AS RENDERED. Not "brighter than it was" — that is a claim
     about history no check can make — but fully opaque, which is the state it
     was not in. */
  ok(`...at full opacity (${a.opacity})`, a.opacity >= 0.95, JSON.stringify(a));
  ok(`...and carrying weight (${a.weight})`, +a.weight >= 600, JSON.stringify(a.weight));
  /* NO COMPARISON AGAINST THE COURT SLUG, and the reason is worth recording.
     The defect was best described as "the safety notice is dimmer than the
     decoration beside it" — the slug is a label and both were drawn at 60%. But
     .chatslug does not exist on any route that mounts this panel: the only
     mountChat call on the site passes heading:false, which drops the "Chat
     <slug>" line entirely. Measured — the arm read `slug null` and passed
     through its own null guard, testing nothing. An assertion that
     short-circuits to true is worse than no assertion, because it reads in a log
     exactly like one that held. The absolute arms above are the real claim. */
  ok("...and the head really has no slug to compare against",
     a.slugOpacity === null, "if a slug renders now, compare against it instead");

  /* THE CONTROL IS HITTABLE. A 12px glyph with no padding is the mistake the
     name button already made once in this file — a label that cannot be hit is a
     control that does not exist. */
  ok("there is a dismiss control", a.hasX, JSON.stringify(a));
  /* 18px, AND THE NUMBER COMES FROM HAVING MEASURED IT. The first version used
     .1rem of side padding and rendered an 11x12 box while the comment beside it
     claimed 20 — so the padding was raised until the claim was true, rather than
     the claim lowered until the padding passed. */
  ok(`...big enough to hit (${a.xw}x${a.xh})`, a.xw >= 18 && a.xh >= 18, JSON.stringify(a));

  /* IT DISMISSES THE SENTENCE, not just the button. Hiding the button alone
     leaves the notice on screen with no way to remove it, which is worse than
     not offering the control. */
  await page.click('.chatwarn .chatwarnx');
  await new Promise(r => setTimeout(r, 300));
  const b = await look();
  ok("clicking it puts the warning away", b.hidden === true || !b.onScreen, JSON.stringify(b));

  /* AND IT STAYS AWAY. A dismissal that returns on the next poll or the next
     page is not a dismissal; the panel rebuilds its shell on every mount, so
     this is the arm that says the choice outlived the DOM that took it. */
  await reopen();
  const c = await look();
  ok("...and stays away across a reload", c.hidden === true || !c.onScreen, JSON.stringify(c));

  /* THE COPY IS STILL THERE TO BE FOUND. Dismissed means not shown, not deleted:
     the sentence has to survive in the panel so clearing site data — or a
     different browser — shows it again. */
  ok("...with the sentence still in the panel, only hidden",
     /nobody can move funds for you/.test(c.text || ""), JSON.stringify(c.text));

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
