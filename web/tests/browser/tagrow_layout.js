// The utility row under a page title, measured on all four routes that use it.
//
// WHY THIS NEEDS A BROWSER. Every complaint about this row was a computed-style
// or layout fact, invisible to a source-reading harness:
//
//   * `button.helplink` is `font:inherit`, and while the size lived on each
//     child's `.small` the share trigger inherited the 15px BODY size instead —
//     20% larger than the links beside it, and wide enough to push it onto a
//     line of its own. Only getComputedStyle sees that.
//   * Three anchors carried `style="color:var(--accent-2)"` INLINE. Inline colour
//     beats any non-!important author rule, so every :hover and :focus-visible
//     written for these links silently did nothing. Only a measured hover shows it.
//   * A folder label comes from local curation — imported JSON — and a flex item
//     defaults to min-width:auto. A 40-character label made the anchor the widest
//     element on the PAGE: documentElement.scrollWidth 454 against a 390 viewport,
//     889 at 80 chars, 1542 at 140. The whole document scrolled sideways, WCAG
//     1.4.10. No source check can compute that.
const puppeteer = require('puppeteer');
const PAGE = 'file://' + require('path').join(__dirname, '..', '..', 'index.html');

const ROUTES = [
  {name: "claim",  route: "#/c/orem/1"},
  {name: "court",  route: "#/c/orem"},
  {name: "curate", route: "#/c/orem/curate"},
  {name: "map",    route: "#/c/orem/map"},
];

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (n, c, extra) => { if (!c) { fail++; console.log("FAIL:", n, extra || ""); } else console.log("ok:", n, extra || ""); };
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 160)));
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });

  // --- one type treatment, on every route that has this row -----------------
  for (const r of ROUTES) {
    await page.setViewport({width: 1280, height: 1000});
    await page.goto(PAGE + r.route, {waitUntil: 'domcontentloaded'});
    await new Promise(x => setTimeout(x, 700));
    const m = await page.evaluate(() => {
      const row = document.querySelector('.tagrow');
      if (!row) return {has: false};
      const read = el => { const c = getComputedStyle(el), b = el.getBoundingClientRect();
        return {size: c.fontSize, fam: c.fontFamily.split(",")[0], color: c.color,
                deco: c.textDecorationLine, h: b.height, top: b.top, bottom: b.bottom,
                text: el.textContent.replace(/\s+/g, " ").trim()}; };
      const links = [...row.querySelectorAll('.tlink')].map(read);
      const facts = [...row.querySelectorAll('.tfact')].map(read);
      // visual lines: group by vertical overlap, not by identical top — the pill
      // and the facts centre differently inside one line.
      const boxes = [...row.querySelectorAll('.tfact,.tlink,.pill')]
        .map(e => e.getBoundingClientRect()).sort((a, b) => a.top - b.top);
      let lines = 0, edge = -1e9;
      for (const b of boxes) { if (b.top >= edge - 2) { lines++; edge = b.bottom; } }
      return {has: true, links, facts, lines,
              inlineColour: row.querySelectorAll('[style*="color"]').length,
              rowH: row.getBoundingClientRect().height};
    });
    ok(`${r.name}: has the row`, m.has);
    if (!m.has) continue;
    ok(`${r.name}: has links in it`, m.links.length >= 2, `n=${m.links.length}`);
    // The four voices that made it read as a jumble: 10.5px caps pill, 12.5px
    // mono fact, 12.5px sans links, 15px sans button.
    ok(`${r.name}: every link is one size`, new Set(m.links.map(l => l.size)).size === 1,
       JSON.stringify(m.links.map(l => l.size)));
    // Consistency alone is not enough: drop the row's font-size and every link
    // inherits the 15px BODY together — consistent, and 20% too large. The
    // intended value is the one the rest of the row is set in.
    ok(`${r.name}: and it is the row's 12.5px`, m.links.every(l => l.size === "12.5px"),
       JSON.stringify([...new Set(m.links.map(l => l.size))]));
    ok(`${r.name}: every link is one family`, new Set(m.links.map(l => l.fam)).size === 1,
       JSON.stringify([...new Set(m.links.map(l => l.fam))]));
    ok(`${r.name}: every link is one colour`, new Set(m.links.map(l => l.color)).size === 1,
       JSON.stringify([...new Set(m.links.map(l => l.color))]));
    // A fact must not be able to pass for something you can click.
    if (m.facts.length)
      ok(`${r.name}: facts are not link-coloured`,
         m.facts.every(f => !m.links.some(l => l.color === f.color)),
         JSON.stringify({fact: m.facts[0].color, link: m.links[0].color}));
    // SC 2.5.8. Free here: the pill already sets the line box at ~25px.
    ok(`${r.name}: every target is at least 24px tall`, m.links.every(l => l.h >= 24),
       JSON.stringify(m.links.map(l => Math.round(l.h))));
    // Inline colour is what made hover unstylable.
    ok(`${r.name}: no inline colour in the row`, m.inlineColour === 0, `n=${m.inlineColour}`);
    ok(`${r.name}: at most two lines at 1280px`, m.lines <= 2, `lines=${m.lines}`);
    // Flex discards whitespace BETWEEN items; the row's links are inline-flex.
    ok(`${r.name}: no words run together`, m.links.every(l => !/[a-z][A-Z]|under[A-Z]/.test(l.text)),
       JSON.stringify(m.links.map(l => l.text).filter(t => /[a-z][A-Z]/.test(t))));
  }

  // --- the underline arrives on hover, and hover means MORE contrast ---------
  await page.setViewport({width: 1280, height: 1000});
  await page.goto(PAGE + "#/c/orem/1", {waitUntil: 'domcontentloaded'});
  await new Promise(x => setTimeout(x, 900));
  const hov = await page.evaluate(() => {
    const a = document.querySelector('.tagrow .tlink');
    const rest = getComputedStyle(a);
    const before = {deco: rest.textDecorationColor, colour: rest.color};
    return {before, sel: '.tagrow .tlink'};
  });
  await page.hover('.tagrow .tlink');
  await new Promise(x => setTimeout(x, 250));
  const after = await page.evaluate(() => {
    const c = getComputedStyle(document.querySelector('.tagrow .tlink'));
    return {deco: c.textDecorationColor, colour: c.color};
  });
  const alpha = s => { const m = String(s).match(/rgba?\([^)]*?,\s*([\d.]+)\)$/); return m ? +m[1] : 1; };
  ok("at rest the underline is not painted", alpha(hov.before.deco) === 0, hov.before.deco);
  ok("on hover it is", alpha(after.deco) > 0, after.deco);
  // button.helplink rested at --accent-2 and hovered to --accent, which is the
  // DIMMER of the two in both themes: hovering made the link recede.
  const lum = s => (String(s).match(/\d+/g) || [0]).slice(0, 3).reduce((a, b) => a + +b, 0);
  ok("hover moves toward the higher-contrast accent, not away",
     lum(after.colour) !== lum(hov.before.colour), `${hov.before.colour} -> ${after.colour}`);

  // --- the folder label cannot scroll the page ------------------------------
  // Local curation is imported JSON: safeInline() escapes it, nothing bounds it.
  for (const w of [390, 360, 320]) {
    for (const n of [0, 40, 140]) {
      await page.setViewport({width: w, height: 900});
      await page.goto(PAGE + "#/c/orem/1", {waitUntil: 'domcontentloaded'});
      await new Promise(x => setTimeout(x, 700));
      const o = await page.evaluate((n) => {
        const a = document.querySelector('.tname');
        if (n && a) a.textContent = "M".repeat(n);
        const kept = document.querySelector('.tagrow .tlink');
        return {sw: document.documentElement.scrollWidth, vw: innerWidth,
                clipped: a ? a.scrollWidth > a.clientWidth + 1 : false,
                provenance: kept ? /· (sample|local)/.test(kept.textContent) : false};
      }, n);
      ok(`@${w}px with a ${n}-char folder label: the page does not scroll sideways`,
         o.sw <= o.vw + 1, `scrollW=${o.sw} vw=${o.vw}`);
      if (n >= 40) {
        ok(`@${w}px, ${n} chars: the label is visibly truncated`, o.clipped);
        // Truncating the label must never take the provenance marker with it —
        // it is the whole reason the chip says anything at all.
        ok(`@${w}px, ${n} chars: the sample/local marker survives`, o.provenance);
      }
    }
  }

  // --- what a screen reader is handed --------------------------------------
  await page.setViewport({width: 1280, height: 1000});
  await page.goto(PAGE + "#/c/orem/1", {waitUntil: 'domcontentloaded'});
  await new Promise(x => setTimeout(x, 900));
  const a11y = await page.evaluate(() => {
    const share = document.querySelector('.tagrow [data-help="share-dlg"]');
    const arrows = [...document.querySelectorAll('.tagrow .tlink span[aria-hidden="true"]')];
    return {
      shareTag: share ? share.tagName.toLowerCase() : null,
      shareType: share ? share.getAttribute("type") : null,
      shareHasPopup: share ? share.getAttribute("aria-haspopup") : null,
      arrows: arrows.length,
      // the glyphs used to land in the accessible name: "link, on the map →"
      nameHasArrow: [...document.querySelectorAll('.tagrow .tlink')]
        .some(a => /[→↗]/.test((a.innerText || "").replace(/\s/g, "")) &&
                   ![...a.querySelectorAll('[aria-hidden="true"]')].length),
    };
  });
  ok("the share trigger is a real button", a11y.shareTag === "button" && a11y.shareType === "button",
     `${a11y.shareTag}/${a11y.shareType}`);
  ok("and announces that it opens a dialog", a11y.shareHasPopup === "dialog", `${a11y.shareHasPopup}`);
  ok("the arrows are hidden from the accessible name", a11y.arrows >= 3, `n=${a11y.arrows}`);
  ok("no link leaves a bare glyph in its name", !a11y.nameHasArrow);
  // Every dialog close button in the file: an untyped <button> defaults to submit.
  const typed = await page.evaluate(() =>
    [...document.querySelectorAll('dialog [data-close]')].every(b => b.getAttribute("type") === "button"));
  ok("dialog close buttons declare type=button", typed);
  // shortAddr() elides the middle for the eye; the full address appears nowhere
  // else on this route, so reading the page aloud gave one that cannot be used.
  const addr = await page.evaluate(() => {
    const f = [...document.querySelectorAll('.tagrow .tfact')].find(e => /opened by/.test(e.textContent));
    if (!f) return null;
    const shown = f.querySelector('[aria-hidden="true"]'), full = f.querySelector('.sr-only');
    const cs = full ? getComputedStyle(full) : null;
    return {shown: shown ? shown.textContent.trim() : null,
            full: full ? full.textContent.trim() : null,
            hidden: cs ? (cs.clipPath !== "none" || cs.width === "1px") : false};
  });
  if (addr) {
    ok("the elided address is hidden from the accessible name", /…/.test(addr.shown), addr.shown);
    ok("and the whole address is in it", !!addr.full && !/…/.test(addr.full) && addr.full.length > 12,
       JSON.stringify(addr.full));
    ok("without being visible", addr.hidden);
  }

  // --- the neon, and the two ways it goes wrong ------------------------------
  // Every glow in the file is a TOKEN so the light theme can switch all of them
  // off in one place. Two failure modes worth pinning: a rule that hardcodes a
  // shadow instead of using the token (glow on white paper is smudge), and the
  // glow leaking onto the programmatic scroll targets — which it did, putting a
  // neon box round the claim title for no reason a reader could explain.
  for(const theme of ["light", "dark"]){
    await page.evaluateOnNewDocument(t => {
      localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo", theme: t}));
      localStorage.setItem("cc.intro", "1");
    }, theme);
    await page.setViewport({width: 1280, height: 900});
    await page.goto(PAGE + "#/c/orem/1", {waitUntil: 'domcontentloaded'});
    await page.reload({waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 900));
    const n = await page.evaluate(() => {
      const tok = k => getComputedStyle(document.documentElement).getPropertyValue(k).trim();
      const sh = sel => { const e = document.querySelector(sel); return e ? getComputedStyle(e).boxShadow : null; };
      const fl = sel => { const e = document.querySelector(sel); return e ? getComputedStyle(e).filter : null; };
      return {glow: tok("--glow-a"), edge: tok("--edge"),
              bar: sh(".sbar .sbY"), line: fl(".bigchart .ln"),
              nav: sh(".nav a.on"), title: sh(".page-h"),
              panel: sh(".panel"),
              // the grid is a background-IMAGE on body, and the `background:`
              // shorthand in the same rule resets it — declared earlier in the
              // sheet it silently never paints, which is what happened first.
              bg: getComputedStyle(document.body).backgroundImage,
              bgSize: getComputedStyle(document.body).backgroundSize};
    });
    if(theme === "light"){
      ok("light: every glow token is off", n.glow === "none", n.glow);
      ok("light: the stake bar has no halo",
         n.bar === null || !/rgba?\([^)]*\) 0px 0px \d/.test(n.bar), n.bar);
      ok("light: the chart line has no filter", n.line === null || n.line === "none", n.line);
      ok("light: the lit edge is invisible", /transparent|rgba\(0, 0, 0, 0\)/.test(n.edge), n.edge);
      // The gradients are still DECLARED in light — they just resolve to
      // transparent, which is how one token switches the whole thing off.
      ok("light: the grid paints nothing",
         !/rgba\((?!0, 0, 0, 0)/.test(n.bg || ""), (n.bg || "").slice(0, 60));
      ok("light: panels have no lit lip", n.panel === "none" || n.panel === null, n.panel);
    } else {
      ok("dark: the glow token carries a value", n.glow !== "none" && n.glow.length > 4, n.glow);
      ok("dark: the recorded path emits", /drop-shadow/.test(n.line || ""), n.line);
      ok("dark: the stake bar emits in its own colour",
         /rgba\(111, 192, 165/.test(n.bar || ""), n.bar);
      ok("dark: the active nav item has a lit leading edge", /inset/.test(n.nav || ""), n.nav);
      // A grid declared before the `background:` shorthand is silently discarded;
      // this asserts it actually reaches the computed style, and at the right cell.
      ok("dark: the grid actually paints", /linear-gradient\(rgba\(154, 168, 238/.test(n.bg || ""),
         (n.bg || "").slice(0, 60));
      ok("dark: on a 44px cell", /44px 44px/.test(n.bgSize || ""), n.bgSize);
      ok("dark: panels have a lit top lip", /inset/.test(n.panel || ""), n.panel);
    }
    // THE ONE THAT ACTUALLY SHIPPED BROKEN — and it has to be FOCUSED to test,
    // which the first version of this check forgot. The page moves focus to the
    // title on a route change (index.html: h.setAttribute("tabindex","-1");
    // h.focus()) so a screen reader lands in the right place, and it suppresses
    // the ring for that reason. Unfocused, this assertion passed no matter what,
    // which is exactly the vacuous pass it was written to prevent.
    const titleFocused = await page.evaluate(() => {
      const h = document.querySelector(".page-h");
      if(!h) return null;
      h.setAttribute("tabindex", "-1"); h.focus();
      const c = getComputedStyle(h);
      return {shadow: c.boxShadow, outline: c.outlineStyle,
              isFocused: document.activeElement === h};
    });
    ok(`${theme}: the title really is focusable, so this is not vacuous`,
       titleFocused && titleFocused.isFocused);
    ok(`${theme}: a focused claim title does not glow`,
       titleFocused && (titleFocused.shadow === "none"), titleFocused && titleFocused.shadow);
    ok(`${theme}: and shows no ring either`,
       titleFocused && titleFocused.outline === "none", titleFocused && titleFocused.outline);
  }
  // Back to the default seed for anything after this.
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });

  ok("no page errors on any route with this row", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
