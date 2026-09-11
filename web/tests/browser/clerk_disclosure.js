// WHAT THE CLERK IS, said on a page a reader can reach from the chat.
//
// The panel's notice said "the clerk is a model: it can be wrong or be misled"
// and pointed NOWHERE. That is half a disclosure: a reader who wanted to know
// what they were talking to had no page to go to. #/about now carries a section
// on it, and the notice's own phrase is the link.
//
// RENDERED, NOT SLICED OUT OF THE SOURCE, and that is deliberate. The nearest
// existing check reads the about page by slicing web/index.html between two
// <h2> markers, and its own comment records a bug that slipped past it for
// exactly that reason — an HTML comment is still present in source, so prose
// assertions can pass against text no reader sees. Everything here is asked of
// the page the browser built.
//
// AND THE LINK IS CLICKED. "The notice points nowhere" was the defect; asserting
// an href exists would not have caught it, because an href to a route that does
// not render is still an href.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 950});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // ---- the page itself ------------------------------------------------------
  await page.goto(PAGE + '#/about', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 900));

  const sec = await page.evaluate(() => {
    const h = [...document.querySelectorAll('h2')]
      .find(e => /clerk/i.test(e.textContent || ''));
    if (!h) return null;
    // Everything from the heading to the next h2 — the section as a reader sees
    // it, with no markup and no comments.
    let t = '', n = h.nextElementSibling;
    while (n && n.tagName !== 'H2') { t += ' ' + (n.textContent || ''); n = n.nextElementSibling; }
    const r = h.getBoundingClientRect();
    return {heading: (h.textContent || '').trim(), text: t.replace(/\s+/g, ' ').trim(),
            onScreen: r.width > 2 && r.height > 2};
  });
  ok("#/about has a section about the clerk", !!sec, JSON.stringify(sec));
  ok("...that is actually painted", !!(sec && sec.onScreen), JSON.stringify(sec && sec.heading));
  ok(`...with prose under it (${sec ? sec.text.length : 0} chars)`,
     !!(sec && sec.text.length > 400), JSON.stringify(sec && sec.text.slice(0, 90)));

  /* WHAT IT MUST SAY. Each of these is a thing the site actually enforces or a
     limit it actually has — the claims and the code were written together, and a
     disclosure that drifts from what the code does is worse than none, because it
     is a promise the site stops keeping without anybody noticing. */
  const t = (sec && sec.text) || '';
  for (const [what, re] of [
    ["it is a model, not a person", /language model/i],
    ["its name is reserved", /name is reserved/i],
    ["it takes no side on a claim", /takes no side/i],
    ["no trading or financial advice", /no trading, financial, legal, tax or medical advice/i],
    ["it will not help an attack", /will not help anyone attack/i],
    ["it never touches a seed phrase or key", /seed\s*phrase or a private key/i],
    ["an address or off-site link is withheld BEFORE posting", /withheld before it is posted/i],
    ["it can be wrong", /can be wrong/i],
    ["a reader can push it around", /pushed\s*around/i],
    ["its instructions are in a channel readers cannot write to", /channel no reader can write into/i],
    ["...and that is called a defence rather than a guarantee", /defence and not a guarantee/i],
    ["nothing it says is a ruling or advice", /Nothing it says is a ruling, a verdict, or advice/i],
    ["the chain is the authority", /read the court's own page on the chain/i],
    ["silence is usually the cost gate", /passes on everything else/i],
  ]) {
    ok("...and says " + what, re.test(t), JSON.stringify(t.slice(0, 120)));
  }

  /* AND IT MUST NOT OVERPROMISE. The one failure mode of a page like this is a
     sentence that reads as a guarantee — "cannot be manipulated", "will never".
     The clerk CAN be pushed around and the page has to keep saying so. */
  for (const [what, re] of [
    ["cannot be manipulated", /cannot be (manipulated|fooled|tricked)/i],
    ["is always right/accurate", /always (right|accurate|correct)/i],
    ["is a guarantee", /we guarantee|is guaranteed/i],
  ]) {
    ok("...and does not claim it " + what, !re.test(t), JSON.stringify(t.slice(0, 120)));
  }

  // ---- the route from the chat notice --------------------------------------
  await page.goto(PAGE + '#/c/orem', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 1400));

  const link = await page.evaluate(() => {
    const a = document.querySelector('.chatwarn a');
    if (!a) return null;
    const r = a.getBoundingClientRect();
    const cs = getComputedStyle(a);
    return {text: (a.textContent || '').trim(), href: a.getAttribute('href'),
            onScreen: r.width > 2 && r.height > 2,
            underlined: /underline/.test(cs.textDecorationLine),
            // it must not read as quieter than the warning it sits inside
            weight: cs.fontWeight, opacity: +cs.opacity};
  });
  ok("the chat notice carries a link", !!link, JSON.stringify(link));
  ok(`...which is the phrase itself ("${link && link.text}")`,
     !!(link && /clerk is a model/i.test(link.text)), JSON.stringify(link));
  ok("...pointing at the about page", !!(link && link.href === '#/about'), JSON.stringify(link));
  ok("...visible and underlined, since colour cannot say it is clickable here",
     !!(link && link.onScreen && link.underlined), JSON.stringify(link));
  ok(`...and no quieter than the warning around it (weight ${link && link.weight})`,
     !!(link && +link.weight >= 600 && link.opacity >= 0.95), JSON.stringify(link));

  /* THE CLICK. This is the arm the original defect would have failed: a notice
     that says "the clerk is a model" and goes nowhere. */
  await page.click('.chatwarn a');
  await new Promise(r => setTimeout(r, 900));
  const landed = await page.evaluate(() => ({
    hash: location.hash,
    clerkHeading: [...document.querySelectorAll('h2')]
      .some(e => /clerk/i.test(e.textContent || '')),
  }));
  ok(`clicking it goes to the about page (${landed.hash})`,
     landed.hash === '#/about', JSON.stringify(landed));
  ok("...and the clerk section is there when you arrive", landed.clerkHeading,
     JSON.stringify(landed));

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
