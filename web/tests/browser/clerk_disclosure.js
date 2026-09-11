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
// THE PANEL MOVED OUT OF THE RAIL. It is a view of its own at
// #/c/<slug>/chat — "it's probably a bad idea to have chat in the sidebar to
// begin with" — so this harness visits the panel's own page rather than a
// court's docket. The arms below are unchanged: what they measure is the panel,
// and the panel is the same panel.

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

  /* THE PANEL NO LONGER POINTS HERE, AND THAT IS THE CHANGE, NOT A BREAKAGE.
     Everything below this line used to be about the route from the chat notice:
     that the notice carried a link, that the link was the phrase "the clerk is a
     model" itself, that it was underlined and no quieter than the sentence around
     it, and -- the arm the original defect would have failed -- that clicking it
     actually landed on a rendered #/about. The notice was removed from the panel
     on the owner's instruction as too wordy, so there is no link left to click.
     WHAT IS LEFT IS THE PAGE, AND IT IS UNCHANGED. Every claim above still holds
     and is still measured: what the clerk is, what it refuses, that it can be
     wrong and can be pushed around, and that none of it is worded as a guarantee.
     A reader reaches it from the site's own navigation now rather than from
     inside the room. If a pointer is ever put back in the panel, the arms that
     checked it are in this file's history. */
  await page.goto(PAGE + '#/c/orem/chat', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 1400));
  const panelNotice = await page.evaluate(() => ({
    warn: !!document.querySelector('.chatwarn'),
    anyAboutLink: !!document.querySelector('#chatview a[href="#/about"]'),
  }));
  ok("the panel carries no notice, as asked", panelNotice.warn === false,
     JSON.stringify(panelNotice));
  ok("...and so no link into the disclosure from inside the room",
     panelNotice.anyAboutLink === false, JSON.stringify(panelNotice));

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
