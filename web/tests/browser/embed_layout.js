// Measures the embed routes at the sizes the share snippet actually offers.
//
// WHY THIS NEEDS A BROWSER. An embed's whole promise is that it FITS: it is
// pasted into someone else's article at a fixed width and height, with no
// scrollbar and no chrome. Every way that promise breaks is a layout fact —
// a card taller than the iframe, a word that forces horizontal scroll, a rail
// that is display:none in one place and not another, a `?theme=` that sets an
// attribute nothing is keyed on. Reading the CSS proves none of it. The sibling
// harness (../share_test.js) already checks the snippet's TEXT; this checks
// that what the snippet points at is the right shape.
//
// The sizes are not arbitrary: they are exactly what embedSnippet() emits
// (400x500 for a claim, 400x210 for a court) plus 320 wide, which is what a
// phone gives a max-width:100% iframe in a narrow column. Those two defaults
// were MEASURED WITH THE DISCLOSURE LINE AND THE RECORDED-PATH SPARK SHOWING —
// every card in the sample at 320px wide, tallest claim 479px and tallest court
// 197px — so `ledger/2 @320`
// below is not a spot check, it is the worst case that set the number.
//
// THE FIRST VERSION OF THIS FILE PASSED VACUOUSLY, and that is why the banner
// case below exists. It measured demo mode only, where paintTestClockBanner()
// returns early and there was nothing to disclose — i.e. with the two things
// that add height switched off. The card overflowed by 106px on a seeded chain
// and buried its own exit link, and every assertion here stayed green. A
// measurement taken in the state that cannot fail measures nothing.
const puppeteer = require('puppeteer');
const PAGE = 'file://' + require('path').join(__dirname, '..', '..', 'index.html');

const CASES = [
  {name: "claim",  route: "#/embed/orem/1", w: 400, h: 500},
  {name: "court",  route: "#/embed/orem",   w: 400, h: 210},
  {name: "claim@320", route: "#/embed/orem/1", w: 320, h: 500},
  {name: "court@320", route: "#/embed/orem",  w: 320, h: 210},
  // the tallest card in the sample, in the narrowest column
  {name: "tallest@320", route: "#/embed/ledger/2", w: 320, h: 500},
  // and a claim whose title is long enough to hit the 4-line clamp
  {name: "clamped@320", route: "#/embed/orem/7", w: 320, h: 500},
  // a card for something that is not there — the case where knowing WHICH
  // source was asked matters most
  {name: "missing@320", route: "#/embed/orem/9999", w: 320, h: 500, missing: true},
];

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (n, c, extra) => { if (!c) { fail++; console.log("FAIL:", n, extra || ""); } else console.log("ok:", n, extra || ""); };
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 200)));
  // Demo source, so this harness needs no node — same contract as every other
  // harness here.
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });

  for (const c of CASES) {
    await page.setViewport({width: c.w, height: c.h});
    await page.goto(PAGE + c.route, {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 500));
    const m = await page.evaluate(() => {
      const card = document.querySelector('.emb');
      const rail = document.querySelector('.rail'), nav = document.getElementById('nav');
      const cs = el => el ? getComputedStyle(el).display : "absent";
      const r = card ? card.getBoundingClientRect() : null;
      const title = document.querySelector('.etitle');
      const link = document.querySelector('.efoot a');
      return {
        has: !!card,
        cardW: r ? r.width : 0, cardH: r ? r.height : 0,
        railDisp: cs(rail), navDisp: cs(nav),
        scrollW: document.documentElement.scrollWidth,
        scrollH: document.documentElement.scrollHeight,
        vw: innerWidth, vh: innerHeight,
        embedClass: document.documentElement.classList.contains("embed"),
        titleText: title ? title.textContent.trim() : "",
        titleW: title ? title.getBoundingClientRect().width : 0,
        linkTarget: link ? link.getAttribute("target") : null,
        linkRel: link ? link.getAttribute("rel") : null,
        // every anchor that leaves the card, not just the footer one
        outLinks: [...document.querySelectorAll('.emb a[href^="#"]')].map(a=>({
          t:a.getAttribute("target"), r:a.getAttribute("rel"), h:a.getAttribute("href")})),
        linkHref: link ? link.getAttribute("href") : null,
        bodyBg: getComputedStyle(document.body).backgroundColor,
        srcNote: (document.querySelector('.esrc') || {}).textContent || "",
        cardText: card ? card.textContent.replace(/\s+/g, " ").trim() : "",
        srcW: document.querySelector('.esrc')
          ? document.querySelector('.esrc').getBoundingClientRect().width : 0,
      };
    });
    const t = `${c.name} ${c.w}x${c.h}`;
    ok(`${t}: renders a card`, m.has);
    ok(`${t}: marked as an embed`, m.embedClass);
    ok(`${t}: no rail`, m.railDisp === "none" || m.railDisp === "absent", `rail=${m.railDisp}`);
    ok(`${t}: no nav`, m.navDisp === "none" || m.navDisp === "absent", `nav=${m.navDisp}`);
    // The two that make an iframe look broken on someone else's page.
    ok(`${t}: no horizontal scroll`, m.scrollW <= m.vw + 1, `scrollW=${m.scrollW} vw=${m.vw}`);
    ok(`${t}: fits the height the snippet asks for`, m.scrollH <= c.h + 1,
       `scrollH=${m.scrollH} h=${c.h}`);
    ok(`${t}: card fills the width`, m.cardW >= m.vw - 2, `cardW=${m.cardW.toFixed(1)}`);
    // A not-found card carries a sentence instead of a title, so the title
    // assertions are scoped rather than dropped — the card still has to fit,
    // still has to disclose, and still has to offer the way out.
    if(!c.missing){
      ok(`${t}: the title is inside the card`, m.titleW <= m.cardW + 1,
         `titleW=${m.titleW.toFixed(1)} cardW=${m.cardW.toFixed(1)}`);
      ok(`${t}: the title says something`, m.titleText.length > 3, JSON.stringify(m.titleText.slice(0, 40)));
    } else {
      ok(`${t}: says plainly that there is nothing here`, /No claim/.test(m.cardText || ""),
         JSON.stringify((m.cardText || "").slice(0, 50)));
    }
    // An embed's link must leave the iframe, or the reader gets the whole app
    // inside a 400px box — but in a NEW TAB, not by replacing the article the
    // reader is in. _top did the latter; a live embed.polymarket.com card uses
    // _blank on all six of its links back, and so does this.
    ok(`${t}: the link opens a new tab`, m.linkTarget === "_blank", `target=${m.linkTarget}`);
    ok(`${t}: and does not hand over the opener`, /noopener/.test(m.linkRel || ""), `rel=${m.linkRel}`);
    ok(`${t}: the link is attributable to the embed`, /from=embed/.test(m.linkHref || ""),
       `href=${m.linkHref}`);
    // The rail carries "Demo data" on the full page and is display:none here,
    // so without this the card presents the offline sample as a chain record on
    // somebody else's website. Demo is the DEFAULT for any first-time reader.
    // Polymarket's card links back from its logo, its title, its chart and each
    // outcome. Ours had exactly one, in the footer.
    ok(`${t}: links back from more than one place`, m.outLinks.length >= (c.missing ? 1 : 3),
       `links=${m.outLinks.length}`);
    ok(`${t}: every one opens a new tab, with noopener`,
       m.outLinks.every(l=>l.t === "_blank" && /noopener/.test(l.r || "")),
       JSON.stringify(m.outLinks.map(l=>l.t + "/" + l.r)));
    ok(`${t}: every one is attributable`, m.outLinks.every(l=>/from=embed/.test(l.h || "")),
       JSON.stringify(m.outLinks.map(l=>l.h)));
    ok(`${t}: says where its numbers came from`, /no chain|set by hand/.test(m.srcNote || ""),
       `note=${JSON.stringify(m.srcNote)}`);
    ok(`${t}: the note is inside the card`, m.srcW <= m.cardW + 1,
       `noteW=${m.srcW.toFixed(1)} cardW=${m.cardW.toFixed(1)}`);
  }

  // --- the theme parameter, measured rather than assumed --------------------
  // The reload is load-bearing. These URLs differ only in their FRAGMENT, and a
  // fragment-only goto does not reload — it fires hashchange on a document that
  // still carries the previous case's data-theme, so a junk theme appeared to be
  // honoured when in fact the attribute was left over. An iframe's src never
  // changes in the field, so a real embed always gets the fresh load this forces.
  const bg = async (q) => {
    await page.setViewport({width: 500, height: 400});
    await page.goto(PAGE + "#/embed/orem/1" + q, {waitUntil: 'domcontentloaded'});
    await page.reload({waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 400));
    return page.evaluate(() => ({
      bg: getComputedStyle(document.body).backgroundColor,
      attr: document.documentElement.getAttribute("data-theme"),
    }));
  };
  const light = await bg("?theme=light"), dark = await bg("?theme=dark");
  ok("?theme=light sets the attribute", light.attr === "light", `attr=${light.attr}`);
  ok("?theme=dark sets the attribute", dark.attr === "dark", `attr=${dark.attr}`);
  // The attribute is only worth setting if something is keyed on it.
  ok("the two themes actually paint differently", light.bg !== dark.bg,
     `${light.bg} vs ${dark.bg}`);
  const lum = s => { const p = s.match(/\d+/g) || [0]; return +p[0] + +(p[1]||0) + +(p[2]||0); };
  ok("light is the lighter of the two", lum(light.bg) > lum(dark.bg),
     `${lum(light.bg)} > ${lum(dark.bg)}`);
  // A junk theme must fall through to the reader's own, not to an attribute
  // with a bogus value that overrides prefers-color-scheme with nothing.
  const junk = await bg('?theme=chartreuse');
  ok("a junk theme is ignored entirely", junk.attr === null || junk.attr === "", `attr=${junk.attr}`);
  // No theme at all must ALSO leave the attribute alone rather than clearing it:
  // the reader may have chosen dark in the app itself, and localStorage is shared
  // with the iframe. "Follows the reader's own theme" means theirs, not the OS's.
  const none = await bg('');
  ok("no theme leaves the reader's own in place", none.attr === null || none.attr === "",
     `attr=${none.attr}`);

  // --- the action ------------------------------------------------------------
  // Polymarket's card ends in two outcome buttons; ours ended in nothing, so a
  // reader had nowhere to go but the small print. These must (a) use this
  // realm's verbs and not a market's, (b) navigate rather than sign — an iframe
  // on someone else's page is the last place for a wallet interaction — and
  // (c) appear ONLY while the claim is open, since staking freezes the moment
  // an answer posts and the realm would refuse the transaction.
  await page.setViewport({width: 400, height: 500});
  for(const [route, phase, want] of [["#/embed/orem/1", "open", true],
                                     ["#/embed/orem/2", "answered", false],
                                     ["#/embed/orem/4", "settled", false],
                                     ["#/embed/orem/3", "disputed", false]]){
    await page.goto(PAGE + route, {waitUntil: 'domcontentloaded'});
    await page.reload({waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 450));
    const a = await page.evaluate(() => {
      const as = [...document.querySelectorAll('.eact')];
      const row = document.querySelector('.eacts');
      return {n: as.length,
        text: as.map(x => x.textContent.replace(/\s+/g, " ").trim()),
        href: as.map(x => x.getAttribute("href")),
        target: as.map(x => x.getAttribute("target")),
        oneRow: row ? Math.round(row.getBoundingClientRect().height) <= 40 : null,
        over: document.documentElement.scrollHeight - innerHeight};
    });
    ok(`${phase}: ${want ? "offers the two sides" : "offers no stake action"}`,
       (a.n === 2) === want, `n=${a.n}`);
    ok(`${phase}: card still fits`, a.over <= 0, `over=${a.over}px`);
    if(!want) continue;
    ok(`${phase}: named with this realm's verb`,
       a.text.every(t => /^Stake (YES|NO)/.test(t)), JSON.stringify(a.text));
    // The line this must not cross: a claim is not bought, sold or priced.
    ok(`${phase}: never a market's words`,
       !a.text.some(t => /\bbuy|sell|odds|price|¢|\$/i.test(t)), JSON.stringify(a.text));
    ok(`${phase}: each carries the side it means`,
       a.href.some(h => /side=yes$/.test(h)) && a.href.some(h => /side=no$/.test(h)),
       JSON.stringify(a.href));
    ok(`${phase}: they navigate, not sign`,
       a.href.every(h => h.startsWith("#/c/")) && a.target.every(t => t === "_blank"),
       JSON.stringify(a.href));
    ok(`${phase}: the actions stay on one row`, a.oneRow, "row wrapped");
  }

  // ...and the side must actually land somewhere, or the button lied.
  await page.setViewport({width: 1200, height: 900});
  await page.goto(PAGE + "#/c/orem/1?from=embed&side=no", {waitUntil: 'domcontentloaded'});
  await page.reload({waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 1200));
  const landed = await page.evaluate(() => {
    const t = document.getElementById("stake-ticket");
    const picked = [...document.querySelectorAll(".btn.picked")].map(b => b.className);
    return {ticket: !!t, picked,
            inView: t ? (t.getBoundingClientRect().top < innerHeight
                         && t.getBoundingClientRect().bottom > 0) : false};
  });
  ok("?side= lands on the stake panel", landed.ticket && landed.inView);
  ok("and marks the side that was asked for",
     landed.picked.length === 1 && /\bno\b/.test(landed.picked[0]), JSON.stringify(landed.picked));
  // A frozen claim has no panel to point at; the link must not throw.
  const errsBefore = errs.length;
  await page.goto(PAGE + "#/c/orem/2?from=embed&side=yes", {waitUntil: 'domcontentloaded'});
  await page.reload({waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 1000));
  ok("a side link to a frozen claim is harmless", errs.length === errsBefore,
     errs.slice(errsBefore).join(" | "));

  // --- the claim's own events, dated -----------------------------------------
  // The claim page gives this a whole section; a card that shows only where the
  // stake ended up says nothing about how the claim got there. It costs no
  // extra read — ClaimTimeline is already fetched for the chart's dates.
  await page.setViewport({width: 400, height: 500});
  for(const [route, phase, want] of [["#/embed/orem/1", "open", ["opened"]],
                                     ["#/embed/orem/2", "answered", ["opened","answered"]],
                                     ["#/embed/orem/7", "provisional", ["opened","answered"]]]){
    await page.goto(PAGE + route, {waitUntil: 'domcontentloaded'});
    await page.reload({waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 450));
    const tr = await page.evaluate(() => {
      const t = document.querySelector('.etrail');
      if(!t) return {has:false};
      return {has:true, text:t.textContent.replace(/\s+/g," ").trim(),
              items:[...t.querySelectorAll('span')].map(s=>s.textContent.replace(/\s+/g," ").trim()),
              future:[...t.querySelectorAll('span.fut')].map(s=>s.textContent.replace(/\s+/g," ").trim()),
              w:t.getBoundingClientRect().width,
              over:document.documentElement.scrollHeight - innerHeight};
    });
    ok(`${phase}: the card carries an event trail`, tr.has, JSON.stringify(tr));
    if(!tr.has) continue;
    ok(`${phase}: naming the events that happened`,
       want.every(w => tr.items.some(i => i.startsWith(w))), JSON.stringify(tr.items));
    // Every event carries a date, or the trail is just a list of words.
    ok(`${phase}: each one is dated`,
       tr.items.every(i => /\d+ (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)/.test(i)),
       JSON.stringify(tr.items));
    // A deadline the realm WILL gate on is not a thing that happened.
    ok(`${phase}: pending deadlines are marked apart from history`,
       tr.future.every(f => /settles|reopenable/.test(f)), JSON.stringify(tr.future));
    ok(`${phase}: it stays inside the card`, tr.w <= 400, `w=${Math.round(tr.w)}`);
    ok(`${phase}: and the card still fits`, tr.over <= 0, `over=${tr.over}px`);
  }
  // The footer's "filed" would repeat the trail's own "opened".
  await page.goto(PAGE + "#/embed/orem/1", {waitUntil: 'domcontentloaded'});
  await page.reload({waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 450));
  const dup = await page.evaluate(() => ({
    trail: !!document.querySelector('.etrail'),
    filed: (document.querySelector('.ewhen') || {textContent:""}).textContent.trim()}));
  ok("the footer does not repeat the opening date", dup.trail && dup.filed === "",
     JSON.stringify(dup));

  // --- the recorded path, in the card ---------------------------------------
  // A card showing only the final ratio throws away the thing worth quoting:
  // that the stake moved. The spark is a fixed 52px so it cannot become a third
  // unbounded term next to the title and the court name.
  await page.setViewport({width: 500, height: 400});
  await page.goto(PAGE + "#/embed/orem/1", {waitUntil: 'domcontentloaded'});
  await page.reload({waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 600));
  const spark = await page.evaluate(() => {
    // THE CARD'S CHART IS THE CLAIM PAGE'S CHART NOW, sharing its classes rather
    // than a private .eline/.efill/.e50 vocabulary — that was the point of the
    // change, so this probe follows it. `.espark` is the FIGURE; the svg is
    // inside it, which is where the aria-label lives.
    const fig = document.querySelector('.espark');
    if(!fig) return {has:false};
    const sv = fig.tagName.toLowerCase() === 'svg' ? fig : fig.querySelector('svg');
    if(!sv) return {has:false};
    const r = sv.getBoundingClientRect();
    const line = sv.querySelector('.ln');
    const dd = line ? line.getAttribute('d') : "";
    // Step-after, asserted STRUCTURALLY rather than by comparing coordinates: the
    // path is built from H and V commands, so a diagonal cannot be expressed at
    // all. An `L` appearing here would mean somebody started interpolating —
    // drawing motion between two samples that the chain never recorded.
    return {has:true, w:r.width, h:r.height,
            segs:(dd.match(/[HV]/g)||[]).length,
            sloped:(dd.match(/L/g)||[]).length,
            labelled: !!sv.getAttribute('aria-label'),
            fill: !!sv.querySelector('.ar'), ref: !!sv.querySelector('.mid')};
  });
  ok("the card draws the recorded path", spark.has);
  // ...and when there is none, says so rather than dropping the chart silently,
  // which made a missing series look like a rendering fault. Same words as the clip.
  const nopath = await (async () => {
    await page.goto(PAGE + "#/embed/orem/7", {waitUntil: 'domcontentloaded'});
    await page.reload({waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 450));
    return page.evaluate(() => ({
      spark: !!document.querySelector('.espark'),
      said: (document.querySelector('.enopath') || {textContent:""}).textContent.trim(),
      over: document.documentElement.scrollHeight - innerHeight}));
  })();
  ok("a claim with no series says so", !nopath.spark && /no recorded path/.test(nopath.said),
     JSON.stringify(nopath));
  ok("and that card still fits", nopath.over <= 0, `over=${nopath.over}px`);
  ok("it spans the card", spark.w >= 300, `w=${Math.round(spark.w||0)}`);
  // NO LONGER A FIXED HEIGHT, and the fixed one was the bug. `height:56px` with
  // preserveAspectRatio="none" stretched a 300x56 viewBox to the card's width:
  // every slope in the trace flattened by ~13% and the endpoint circle drew as an
  // ellipse. The box takes the viewBox's own ratio now, so what this asserts is
  // that the scaling is UNIFORM — the shape a reader shares is the shape the
  // chain recorded.
  ok("the plot keeps the viewBox's aspect, so slopes are true",
     Math.abs(spark.w / spark.h - 300 / 76) < 0.05,
     `w=${Math.round(spark.w)} h=${Math.round(spark.h)} ratio=${(spark.w/spark.h).toFixed(2)}`);
  ok("it has more than one step", spark.segs > 2, `segs=${spark.segs}`);
  ok("every segment is a step, never a slope", spark.sloped === 0, `sloped=${spark.sloped}`);
  ok("it carries the 50% reference", spark.ref);
  ok("and a label for a screen reader", spark.labelled);

  // --- a court name is whatever its creator typed ---------------------------
  // .ehead was flex-wrap:wrap, so a long name turned a one-line head into three
  // and pushed the card 9px past the iframe it was sized for. Measured, not
  // reasoned about: this injects the name and re-renders.
  await page.setViewport({width: 320, height: 500});  // the snippet's own claim height
  await page.goto(PAGE + "#/embed/orem/1", {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 500));
  const longName = await page.evaluate(async () => {
    DEMO.courts.orem.name = "Salt Lake County Consolidated Election Canvass Review Board of Record";
    await render();
    // WAIT FOR THE ENTRY ANIMATION, or measure it instead of the layout.
    // `#main.vin` is 140ms of translateY(5px), so a measurement taken the
    // instant render() returns catches the card 5px down the page and reports
    // exactly 5px of overflow — a number that looks like the 9px layout bug
    // this check was written for and is not one. The route above passes only
    // because the goto is followed by a 500ms settle; this path had none, so
    // the suite went permanently red the day the animation landed.
    await Promise.all(document.getAnimations().map(a => a.finished.catch(() => {})));
    const h = document.querySelector('.ehead');
    return {
      headH: h ? h.getBoundingClientRect().height : 0,
      headLines: h ? Math.round(h.getBoundingClientRect().height / 16) : 0,
      over: document.documentElement.scrollHeight - innerHeight,
      scrollW: document.documentElement.scrollWidth, vw: innerWidth,
      nameClipped: (() => { const n = document.querySelector('.ename');
        return !!n && n.scrollWidth > n.clientWidth + 1; })(),
    };
  });
  ok("a long court name keeps the head on one line", longName.headLines <= 1,
     `headH=${Math.round(longName.headH)}`);
  ok("the name is truncated rather than wrapped", longName.nameClipped);
  ok("a long court name does not overflow the card", longName.over <= 0, `over=${longName.over}px`);
  ok("nor push it sideways", longName.scrollW <= longName.vw + 1, `scrollW=${longName.scrollW}`);

  // --- the page banner must not be able to reach an embed -------------------
  // On a seeded chain paintTestClockBanner() paints a paragraph on every route.
  // Inside a 400x400 card that paragraph was 108px and pushed "Open on Kourt"
  // out of sight. The card now carries the short form and the banner is
  // suppressed; this forces the banner's markup in to prove the suppression is
  // real rather than a demo-mode accident.
  await page.setViewport({width: 500, height: 500});  // the snippet's own claim height
  await page.goto(PAGE + "#/embed/orem/1", {waitUntil: 'domcontentloaded'});
  await page.reload({waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 500));
  const withBanner = await page.evaluate(() => {
    const el = document.getElementById("tcbanner");
    el.innerHTML = `<div class="tcbar"><span class="g">⏱</span><div><b>Test chain — the dates here are fabricated.</b>
      This node's clock was set by hand — it was moved forward 84 days. The clock is sealed, so they are now
      fixed. Balances and stakes are real.</div></div>`;
    el.hidden = false;
    const link = document.querySelector('.efoot a');
    const lr = link ? link.getBoundingClientRect() : null;
    return {
      bannerShown: getComputedStyle(el).display !== "none" && el.getBoundingClientRect().height > 4,
      scrollH: document.documentElement.scrollHeight, vh: innerHeight,
      linkVisible: !!lr && lr.bottom <= innerHeight + 1 && lr.top >= -1,
    };
  });
  ok("the page banner cannot paint inside an embed", !withBanner.bannerShown);
  ok("an embed does not overflow even when the banner is forced",
     withBanner.scrollH <= withBanner.vh + 1, `scrollH=${withBanner.scrollH} vh=${withBanner.vh}`);
  ok("the exit link stays on screen", withBanner.linkVisible);

  // --- a missing claim is a card, not a blank iframe ------------------------
  await page.setViewport({width: 500, height: 400});
  await page.goto(PAGE + "#/embed/nosuch/9999", {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 400));
  const miss = await page.evaluate(() => {
    const c = document.querySelector('.emb');
    return {has: !!c, text: c ? c.textContent.replace(/\s+/g, " ").trim() : "",
            link: !!document.querySelector('.efoot a')};
  });
  ok("a missing claim still renders a card", miss.has);
  ok("a missing claim still says which source was asked", /no chain|set by hand/.test(miss.text));
  ok("and says what is missing", /No claim/.test(miss.text), JSON.stringify(miss.text.slice(0, 60)));
  ok("and still offers the way out", miss.link);

  ok("no page errors on any embed route", errs.length === 0, errs.slice(0, 2).join(" | "));

  // --- THE ROUTES THIS FILE IS NOT ABOUT, LOADED ANYWAY ----------------------
  // A duplicate `function claimSeries` shipped and broke the COURT DOCKET in
  // both modes — "pts.map is not a function" — and every gate stayed green
  // because nothing ever loaded that page. check-web-dupes.py now catches that
  // specific class at commit time; this catches the general one, which is a
  // route nobody exercises. It is three page loads and an error listener.
  const routeErrs = [];
  const rp = await browser.newPage();
  rp.on('pageerror', e => routeErrs.push(String(e).slice(0, 140)));
  await rp.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await rp.setViewport({width: 1280, height: 1000});
  for(const [route, want] of [["#/", ".card, .courtrow, .grid"],
                              ["#/c/orem", ".docket a.crow"],
                              ["#/c/orem/1", ".stakewrap"],
                              ["#/me", "h1"],
                              ["#/needs", "h1"],
                              ["#/about", "h1"]]){
    const before = routeErrs.length;
    await rp.goto(PAGE + route, {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 900));
    const painted = await rp.evaluate(sel => !!document.querySelector(sel), want);
    ok(`${route} throws nothing`, routeErrs.length === before,
       routeErrs.slice(before).join(" | "));
    ok(`${route} painted something`, painted, `no ${want}`);
  }
  // The specific thing that broke: a sparkline is fed an array, not a Promise.
  await rp.goto(PAGE + "#/c/orem", {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 1000));
  const dock = await rp.evaluate(() => ({
    rows: document.querySelectorAll('.docket a.crow').length,
    sparks: document.querySelectorAll('svg.spark polyline').length,
    pts: [...document.querySelectorAll('svg.spark polyline')].slice(0, 3)
      .map(e => (e.getAttribute('points') || "").split(" ").length)}));
  ok("the docket draws rows", dock.rows > 0, `rows=${dock.rows}`);
  // The three-point spark needs all three series, and the trailing week is not
  // mature on a young claim — so on a real chain the cell rendered EMPTY beside
  // rows that had a number. Show what is known; never draw the missing series.
  const sig = await rp.evaluate(() => {
    const rows = [...document.querySelectorAll('.docket a.crow')].filter(e => e.dataset.id != null);
    return {n: rows.length,
      blank: rows.filter(e => { const px = e.querySelector('.px'); return px && !px.textContent.trim(); }).length,
      sortable: rows.filter(e => e.dataset.yes != null).length};
  });
  ok("no claim's signal cell is blank", sig.blank === 0, `blank=${sig.blank}/${sig.n}`);
  ok("and every claim row can still be sorted", sig.sortable === sig.n,
     `${sig.sortable}/${sig.n}`);
  ok("with sparklines", dock.sparks > 0, `sparks=${dock.sparks}`);
  ok("and each sparkline has real points, not a stringified Promise",
     dock.pts.length > 0 && dock.pts.every(n => n >= 2), JSON.stringify(dock.pts));
  await rp.close();

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
