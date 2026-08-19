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
// (400x400 for a claim, 400x210 for a court) plus 320 wide, which is what a
// phone gives a max-width:100% iframe in a narrow column. Those two defaults
// were MEASURED WITH THE DISCLOSURE LINE AND THE RECORDED-PATH SPARK SHOWING —
// every card in the sample at 320px wide, tallest claim 383px and tallest court
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
  {name: "claim",  route: "#/embed/orem/1", w: 400, h: 400},
  {name: "court",  route: "#/embed/orem",   w: 400, h: 210},
  {name: "claim@320", route: "#/embed/orem/1", w: 320, h: 400},
  {name: "court@320", route: "#/embed/orem",  w: 320, h: 210},
  // the tallest card in the sample, in the narrowest column
  {name: "tallest@320", route: "#/embed/ledger/2", w: 320, h: 400},
  // and a claim whose title is long enough to hit the 4-line clamp
  {name: "clamped@320", route: "#/embed/orem/7", w: 320, h: 400},
  // a card for something that is not there — the case where knowing WHICH
  // source was asked matters most
  {name: "missing@320", route: "#/embed/orem/9999", w: 320, h: 400, missing: true},
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
    await page.setViewport({width: 400, height: 400});
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

  // --- the recorded path, in the card ---------------------------------------
  // A card showing only the final ratio throws away the thing worth quoting:
  // that the stake moved. The spark is a fixed 52px so it cannot become a third
  // unbounded term next to the title and the court name.
  await page.setViewport({width: 400, height: 400});
  await page.goto(PAGE + "#/embed/orem/1", {waitUntil: 'domcontentloaded'});
  await page.reload({waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 600));
  const spark = await page.evaluate(() => {
    const sv = document.querySelector('.espark');
    if(!sv) return {has:false};
    const r = sv.getBoundingClientRect();
    const line = sv.querySelector('.eline');
    const dd = line ? line.getAttribute('d') : "";
    // Step-after: the chain stores change-only samples, so every segment must be
    // horizontal or vertical. A sloped segment would be interpolation — motion
    // the chain never recorded.
    const nums = (dd.match(/-?[\d.]+/g) || []).map(Number);
    let sloped = 0;
    for(let i = 2; i + 1 < nums.length; i += 2)
      if(nums[i] !== nums[i-2] && nums[i+1] !== nums[i-1]) sloped++;
    return {has:true, w:r.width, h:r.height, segs:(dd.match(/L/g)||[]).length, sloped,
            labelled: !!sv.getAttribute('aria-label'),
            fill: !!sv.querySelector('.efill'), ref: !!sv.querySelector('.e50')};
  });
  ok("the card draws the recorded path", spark.has);
  ok("it spans the card", spark.w >= 300, `w=${Math.round(spark.w||0)}`);
  ok("its height is fixed at 52px", Math.round(spark.h) === 52, `h=${spark.h}`);
  ok("it has more than one segment", spark.segs > 2, `segs=${spark.segs}`);
  ok("every segment is a step, never a slope", spark.sloped === 0, `sloped=${spark.sloped}`);
  ok("it carries the 50% reference", spark.ref);
  ok("and a label for a screen reader", spark.labelled);

  // --- a court name is whatever its creator typed ---------------------------
  // .ehead was flex-wrap:wrap, so a long name turned a one-line head into three
  // and pushed the card 9px past the iframe it was sized for. Measured, not
  // reasoned about: this injects the name and re-renders.
  await page.setViewport({width: 320, height: 400});  // the snippet's own claim height
  await page.goto(PAGE + "#/embed/orem/1", {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 500));
  const longName = await page.evaluate(async () => {
    DEMO.courts.orem.name = "Salt Lake County Consolidated Election Canvass Review Board of Record";
    await render();
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
  await page.setViewport({width: 400, height: 400});  // the snippet's own claim height
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
  await page.setViewport({width: 400, height: 400});
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

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
