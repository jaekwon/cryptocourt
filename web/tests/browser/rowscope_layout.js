// Every label-and-value row the overlay draws, measured WHERE IT LANDS.
//
// WHY THIS EXISTS. A `.line` is the overlay's label-and-value row, and every
// rule for one was written as `.ticket .line`. That is invisible in the source:
// the markup a function emits is identical whether or not a ticket happens to be
// somewhere above it, so the same helper renders as two clean grid tracks on the
// ballot and as two bare inline spans on the quality panel, where the page read
//
//     what voting commitsCasting commits the weight you vote with, until...
//
// — the label and its prose printed as one word, with no emphasis and no column.
// Three source-reading tests pinned the exact text of those CSS rules and all
// three passed, because they proved the rule's TEXT and never that anything was
// inside its scope. Only a computed style can tell you which of the two a row
// actually got.
//
// So this crawls the demo the way route_crawl does and asks one question of
// every row it finds: did you come out as a grid? A row that did not is either
// in a container nobody styled or in one somebody renamed.
//
// It is deliberately not a list of routes. The bug was in a panel that renders
// only for a claim in a particular phase, and a hand-written route list is
// exactly the kind of thing that omits it.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');
const MAX_PAGES = 60;

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 160)));
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await page.setViewport({width: 1280, height: 1000});
  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 700));

  const seen = new Set(['#/']);
  const queue = ['#/'];
  const bad = [];
  let visited = 0, rows = 0;

  while (queue.length && visited < MAX_PAGES) {
    const route = queue.shift();
    visited++;
    await page.evaluate(r => { location.hash = r.slice(1); }, route);
    await new Promise(r => setTimeout(r, 260));

    const found = await page.evaluate(() => {
      const out = [];
      for (const el of document.querySelectorAll('.line')) {
        const cs = getComputedStyle(el);
        if (cs.display === 'grid') { out.push({ok: true}); continue; }
        out.push({ok: false, display: cs.display,
                  text: el.innerText.replace(/\s+/g, ' ').slice(0, 60)});
      }
      return out;
    });
    rows += found.length;
    for (const f of found) if (!f.ok) bad.push({route, ...f});

    const links = await page.evaluate(() =>
      [...document.querySelectorAll('.main a[href^="#/"], .rail a[href^="#/"]')]
        .map(a => a.getAttribute('href')));
    for (const h of links) {
      const r = String(h).split('?')[0];
      if (!r.startsWith('#/') || r.startsWith('#/embed/') || seen.has(r)) continue;
      seen.add(r); queue.push(r);
    }
  }

  // --- the lightbox holds the page still ------------------------------------
  // Measured, not assumed: with the lightbox open a wheel took the document to
  // y=400 underneath it. A claim page is thousands of pixels tall, so somebody
  // studying an exhibit scrolls, sees nothing move, scrolls again, and closes to
  // find themselves somewhere else — having lost the claim they were reading.
  //
  // Tested with a real wheel rather than scrollBy, because overflow:hidden stops
  // a user scrolling and does not stop a programmatic scroll: the first version
  // of this measured nothing about the fix and reported it broken.
  await page.evaluate(r => { location.hash = r.slice(1); }, "#/c/orem/3");
  await new Promise(r => setTimeout(r, 500));
  const opened = await page.evaluate(() => {
    const ex = document.querySelector(".exhibits .ex");
    if (!ex) return false;
    ex.click();
    return !!document.querySelector(".lbox");
  });
  ok("an exhibit opens a lightbox", opened);

  // THE PAGE THAT CAN VERIFY SHOULD SAY SO. The realm's own claim page carries a
  // sentence about the fingerprint precisely because gnoweb CANNOT check it;
  // this page can, in the lightbox, and said nothing — the only hint that
  // verification existed was an aria-label reading "full size". The surface that
  // cannot verify announced the promise and the surface that can kept quiet.
  const lede = await page.evaluate(() => {
    const l = document.querySelector(".ex-lede");
    const box = document.querySelector(".exhibits");
    const fig = document.querySelector(".exhibits .ex");
    return {
      text: l ? l.textContent : "",
      first: !!(l && box && (l.compareDocumentPosition(box) & 4)),
      aria: fig ? fig.getAttribute("aria-label") : "",
      // and it is offered only where there is something to check
      vidOnly: typeof claimEvidenceNote === "function"
        && claimEvidenceNote({media: [{kind: "vid", mirrors: ["x"]}]}) === "",
      purged: typeof claimEvidenceNote === "function"
        && claimEvidenceNote({media: [{kind: "img", sha256: "a".repeat(64), purged: true}]}) === "",
    };
  });
  ok("the claim page says its images were fingerprinted",
     /fingerprinted/.test(lede.text), JSON.stringify(lede.text));
  ok("...before the images rather than after them", lede.first);
  ok("...and the affordance says what opening one is for",
     /check it against what was filed/.test(lede.aria), JSON.stringify(lede.aria));
  ok("...offered only when something is checkable", lede.vidOnly && lede.purged);

  // --- a caption in a right-to-left script -----------------------------------
  // The page is lang="en", so its block direction is ltr. An Arabic or Hebrew
  // caption rendered inside it gets its letters in the right order and its
  // SENTENCE in the wrong place — left-aligned, trailing punctuation drawn at
  // the end an ltr reader expects rather than the end the sentence has. Measured
  // as direction:ltr for a caption that is entirely Arabic. dir="auto" asks the
  // browser to take direction from the first strong character.
  const bidi = await page.evaluate(() => {
    const of = text => {
      const h = document.createElement("div");
      h.innerHTML = claimExhibits({media: [{kind: "img", sha256: "a".repeat(64),
        mime: "image/webp", w: 240, h: 160, bytes: 5200, caption: text,
        mirrors: ["https://x/m/" + "a".repeat(64)]}]});
      document.body.appendChild(h);
      const d = getComputedStyle(h.querySelector(".ex-cap")).direction;
      h.remove();
      return d;
    };
    return {ar: of("محضر اجتماع المجلس البلدي، صفحة 14."),
            he: of("מסמך רשמי מהעירייה"),
            en: of("north span rating, 2025 inspection report")};
  });
  // --- a purged exhibit keeps its place and does not pretend to open ---------
  // The tombstone exists so the exhibits around it keep their numbers: a
  // moderator's next call takes an index, and a reader arguing about "the second
  // exhibit" must still mean the same picture tomorrow. Never rendered in the
  // overlay until now — and the slot carried `.ex`, which is cursor:zoom-in,
  // while having no data-ex for the click handler to find.
  const gone = await page.evaluate(() => {
    const media = [
      {kind: "img", sha256: "a".repeat(64), mime: "image/webp", w: 240, h: 160,
       bytes: 5200, caption: "the memo", mirrors: ["https://x/m/" + "a".repeat(64)]},
      {kind: "img", purged: true},
      {kind: "img", sha256: "c".repeat(64), mime: "image/webp", w: 240, h: 160,
       bytes: 5200, caption: "the reply", mirrors: ["https://x/m/" + "c".repeat(64)]},
    ];
    const h = document.createElement("div");
    h.innerHTML = claimExhibits({media});
    document.body.appendChild(h);
    const figs = [...h.querySelectorAll("figure")];
    const out = {
      labels: figs.map(f => (f.querySelector(".ex-n") || {}).textContent || ""),
      tombstone: figs[1] ? figs[1].className : "",
      zoomable: figs[1] ? getComputedStyle(figs[1]).cursor : "",
      openable: figs[1] ? figs[1].hasAttribute("data-ex") : null,
    };
    h.remove();
    return out;
  });
  ok("a purge does not renumber the exhibits around it",
     gone.labels.join("/") === "1 of 3/2 of 3/3 of 3", gone.labels.join("/"));
  ok("...the taken-down slot is marked as gone", /ex-gone/.test(gone.tombstone));
  ok("...and does not offer to open what is not there",
     gone.openable === false && gone.zoomable !== "zoom-in",
     `cursor=${gone.zoomable} data-ex=${gone.openable}`);

  // --- evidence does not depend on what the claim is doing --------------------
  // The last dimension on the list, and the only one that produced nothing. The
  // realm gates media on moderation alone — claimMediaVisible looks at purged and
  // global, never at a phase — and the overlay draws from d.media, so a claim's
  // exhibits are the same whether it is open, answered, disputed or long settled.
  // Verified rather than assumed, and pinned so a phase-shaped branch cannot grow
  // into the evidence path later.
  const phases = await page.evaluate(() => {
    const media = [{kind: "img", sha256: "a".repeat(64), mime: "image/webp", w: 240,
      h: 160, bytes: 5200, caption: "the memo", mirrors: ["https://x/m/" + "a".repeat(64)]}];
    const names = ["open", "answered", "disputed", "provisional", "settled", "provClose", "closed"];
    const drawn = names.map(ph => claimEvidenceNote({phase: ph, media})
                               + claimExhibits({phase: ph, media}));
    return {same: drawn.every(d => d === drawn[0]), any: drawn[0].length > 0,
            // a read that failed yields [] and the page OMITS rather than
            // asserting the claim carries nothing
            onFailure: claimEvidenceNote({media: mediaParse("[]")})
                     + claimExhibits({media: mediaParse("[]")})};
  });
  ok("a claim's evidence renders the same in every phase", phases.same);
  ok("...and there was something to compare", phases.any);
  ok("a media read that failed omits, rather than reporting no evidence",
     phases.onFailure === "", JSON.stringify(phases.onFailure));

  ok("an Arabic caption reads right-to-left", bidi.ar === "rtl", bidi.ar);
  ok("...and a Hebrew one", bidi.he === "rtl", bidi.he);
  ok("...while an English one is unaffected", bidi.en === "ltr", bidi.en);
  if (opened) {
    await page.mouse.move(500, 400);
    await page.mouse.wheel({deltaY: 400});
    await new Promise(r => setTimeout(r, 250));
    const held = await page.evaluate(() => ({y: window.scrollY,
      overflow: getComputedStyle(document.documentElement).overflow}));
    ok("the page behind it does not scroll", held.y === 0,
       `y=${held.y} overflow=${held.overflow}`);
    await page.keyboard.press("Escape");
    await new Promise(r => setTimeout(r, 250));
    const after = await page.evaluate(() => ({
      open: !!document.querySelector(".lbox"),
      overflow: document.documentElement.style.overflow,
      pad: document.documentElement.style.paddingRight}));
    ok("Escape closes it", !after.open);
    ok("...and gives the page its scrolling back", !after.overflow && !after.pad,
       JSON.stringify(after));
  }

  console.log(`\ncrawled ${visited} route(s); measured ${rows} row(s)`);
  ok("every label-and-value row landed in a container that styles it",
     bad.length === 0,
     bad.slice(0, 4).map(b => `${b.route} [${b.display}] "${b.text}"`).join(" | "));

  // THE TRIPWIRE. A crawl that found four rows proves nothing, and this harness
  // would go green on a page where every row had stopped rendering at all —
  // which is the failure it would most want to report. Pinned below the count
  // observed when it was written (104 across 60 routes), loose enough that
  // adding or removing a panel does not fail the build for the wrong reason.
  ok("the crawl actually reached the pages with rows on them", rows >= 60, `saw ${rows}`);
  ok("no page threw while being measured", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
