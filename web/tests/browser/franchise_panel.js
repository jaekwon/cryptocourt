// The meta franchise, as it actually reaches a reader.
//
// WHY A BROWSER CHECK. franchise_test.js calls franchiseHtml directly and proves
// the WORDS; nothing proved the panel is ever filled. fillFranchise is an async
// fill into a slot the court page renders empty, so every failure mode it has is
// invisible to a source harness: the slot never mounted, the fill threw, the
// reads never landed, the court page stopped calling it.
//
// THAT GAP IS NOT THEORETICAL IN THIS FILE. Twice this week a top-level const
// read a name declared below it and threw on load, taking the whole script with
// it — and both times every source harness stayed green, because a harness
// evaluates a slice and sets the names it needs as globals first. One of those
// two was in this very feature: the sample's franchise map, written inside the
// DEMO object, in DEMO_ME's temporal dead zone. check-tdz now catches that
// shape; this catches the rest of the ways a fill can quietly not happen.
//
// AND THE PANEL IS THE ANSWER TO A REPORT. The front page showed a court that had
// burned thirteen thousand GNOT beside a meta court whose supply read zero, and
// the reader asked the only reasonable question: how can there be no meta tokens
// when there were tokens burned? Both figures were true. The entitlement between
// them was the sentence nobody had written.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1440, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  const panel = async slug => {
    await page.goto(PAGE + '#/c/' + slug, {waitUntil: 'domcontentloaded'});
    for (let i = 0; i < 25; i++) {
      const t = await page.evaluate(() => {
        const f = document.getElementById("franchise");
        return f && f.textContent ? f.textContent : "";
      });
      if (t) return t.replace(/\s+/g, " ");
      await new Promise(r => setTimeout(r, 200));
    }
    return "";
  };

  /* AN ORDINARY COURT: the rule, stated where it is earned. */
  const onCourt = await panel("orem");
  ok("a court page fills the franchise panel", !!onCourt, "(never filled)");
  ok("...saying the burn here also earns coin in the meta court",
     /also earns you the meta court's coin/.test(onCourt), onCourt.slice(0, 110));
  /* THE SAME BURN, COUNTED AGAIN — the claim, not the sentence. This pinned "one
     for one with what you burn" and went red when the copy was reworded to "the
     same GNOT credited again there", which says the same thing. What has to hold
     is that the panel says the burn HERE is what earns the coin THERE. */
  ok("...saying the same burn is what earns it",
     /(one for one|the same GNOT|same burn)/i.test(onCourt), onCourt.slice(0, 160));
  /* THE SENTENCE THAT ANSWERS THE REPORT. Without it, meta's zero supply reads as
     the feature being broken rather than as coin that is owed and unminted. */
  ok("...and that nothing is minted until it is claimed",
     /Nothing is minted at the moment of the burn/.test(onCourt));
  ok("...naming the court whose supply that makes meaningful",
     /the meta court's supply counts/.test(onCourt), onCourt);

  /* AND THE NAME IS A WAY IN. The sample carries a meta court precisely so this
     link lands; route_crawl found it dead-ending when it did not. */
  const link = await page.evaluate(() =>
    !!document.querySelector('#franchise a[href="#/c/meta"]'));
  ok("...and the meta court is reachable from the sentence", link);

  /* META'S OWN PAGE SAYS THE INVERSE, and it is the half that has no home
     anywhere else: this coin is not received for GNOT, it is earned. */
  const onMeta = await panel("meta");
  ok("meta's own page fills the panel too", !!onMeta, "(never filled)");
  ok("...saying its coin is earned rather than received for GNOT",
     /not received for GNOT/.test(onMeta) && /earned/.test(onMeta), onMeta.slice(0, 110));
  ok("...and does not offer a link to the page it is already on",
     !(await page.evaluate(() => !!document.querySelector('#franchise a[href="#/c/meta"]'))));

  /* THE REGISTER, HELD HERE TOO. vocab_receive reads a fixed list of routes and
     #/c/meta is not on it, so the one page whose whole subject is how coin is
     obtained would otherwise never be checked for the word. */
  for (const [what, t] of [["a court page", onCourt], ["meta's own page", onMeta]])
    ok(`${what} never says buy`, !/\bbuy|\bpurchas/i.test(t), t.slice(0, 90));

  /* WHERE THE PANEL SITS, as containment rather than as a source regex. The
     section moved out of the court page's top strip and into the Join panel,
     which is both where the burn happens and where a reader returns to claim —
     and "the element exists somewhere on the page" stayed true across that
     move, so only the containment can fail. */
  await page.goto(PAGE + '#/c/orem', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 2500));
  const placed = await page.evaluate(() => {
    const f = document.getElementById("franchise");
    if (!f) return "no #franchise at all";
    const join = f.closest("#join");
    return join ? "in #join" : "outside #join, under " +
      (f.parentElement ? (f.parentElement.id || f.parentElement.className || "?") : "nothing");
  });
  ok("the franchise section is inside the Join panel", placed === "in #join", placed);

  /* THE FOLLOW-UP DIALOG, DRIVEN DIRECTLY. It normally opens on the far side of
     a real burn's seven-second settle, which a browser check cannot reach
     without a wallet — but everything that can go wrong with it is in the
     dialog itself: whether it opens, whether it says the rule, and whether it
     stays dismissed. So it is called the way the buy hook calls it. */
  const dlg = await page.evaluate(async () => {
    try { localStorage.removeItem("cc.franchise"); } catch (e) {}
    if (typeof franchiseFollowup !== "function") return {err: "NO franchiseFollowup IN THE PAGE"};
    await franchiseFollowup("orem");
    const d = document.getElementById("frdlg");
    return {open: !!(d && d.open), text: d ? d.textContent.replace(/\s+/g, " ") : ""};
  });
  ok("a burn's follow-up opens a dialog", !!(dlg && dlg.open), dlg && dlg.err || JSON.stringify(dlg));
  ok("...carrying the same rule the panel states",
     /also earns you the meta court's coin/.test((dlg && dlg.text) || ""),
     ((dlg && dlg.text) || "").slice(0, 120));
  /* AND IT NAMES THE PANEL, because this dialog cannot be reopened once
     dismissed. Telling the reader where the rule stays is what makes dismissing
     it safe rather than a loss. */
  ok("...and says where to find it again",
     /Join this court/.test((dlg && dlg.text) || ""));

  const after = await page.evaluate(async () => {
    const d = document.getElementById("frdlg");
    const btn = d && d.querySelector("[data-frdismiss]");
    if (btn) btn.click();
    const flag = (() => { try { return localStorage.getItem("cc.franchise"); } catch (e) { return null; } })();
    const gone = !document.getElementById("frdlg");
    // A SECOND BURN MUST NOT BRING IT BACK: the panel is the copy that persists.
    await franchiseFollowup("orem");
    return {flag, gone, again: !!document.getElementById("frdlg")};
  });
  ok("dismissing it closes and removes it", !!(after && after.gone), JSON.stringify(after));
  ok("...and remembers, so a second burn does not bring it back",
     after && after.flag === "1" && after.again === false, JSON.stringify(after));

  /* THE POSITIONS PAGE: what is waiting, for the address being viewed. This is
     where "how much do I have" is actually asked. */
  await page.goto(PAGE + '#/me', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 2500));
  const tiles = await page.evaluate(() =>
    [...document.querySelectorAll('.stat')].map(s => ({
      k: ((s.querySelector('.k') || {}).textContent || "").trim(),
      v: ((s.querySelector('.v') || {}).textContent || "").trim()})));
  const waiting = tiles.find(t => /waiting in the meta court/.test(t.k));
  ok("the positions page has a tile for what is waiting", !!waiting, JSON.stringify(tiles.map(t => t.k)));
  ok("...with a figure in it, not an empty cell", !!(waiting && waiting.v), JSON.stringify(waiting));
  /* THE SAMPLE CARRIES BOTH HALVES — coin held AND burn waiting — because they
     are different things and both are true of anyone who has claimed once and
     kept burning since. With only one of them, half the panel has no case. */
  const heldTile = tiles.find(t => /coin held/.test(t.k));
  ok("...beside what is already held, which is the other half",
     !!(heldTile && heldTile.v && !/none/.test(heldTile.v)), JSON.stringify(heldTile));

  /* AND NO CLAIM CONTROL FOR AN ADDRESS THAT IS NOT YOURS. The sample reader has
     an entitlement waiting and no wallet is connected, which is the exact state
     where offering the transaction would be wrong: it would mint to that address
     and be signed by whoever pressed it. The figure is public; the control is
     not. */
  /* FOUND BY ITS LABEL, NOT BY data-func. In demo mode btn() renders the INERT
     form — no data-func at all, because an action wired to sample arguments is a
     trap — so an assertion keyed on that attribute cannot tell a control that is
     present from one that is absent. Measured: it passed with the guard removed,
     which is an arm testing nothing. The label is on both forms. */
  const claim = await page.evaluate(() =>
    [...document.querySelectorAll('button')]
      .some(b => /Claim your meta coin/.test(b.textContent || "")));
  ok("...and no claim control, because no wallet is connected", !claim);

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
