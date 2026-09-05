// THE EYE SITS IN THE LINE, IT DOES NOT TAKE ONE.
//
// The reset at the top of index.html is `img,svg{display:block}`, which is right
// for every picture on the site and wrong for the one glyph that is drawn rather
// than typed. An <svg> dropped straight into a line of text becomes a block and
// takes a line of its own: the set page's heading rendered the eye above the
// name, two lines where there is one thing. Reported on a live set page.
//
// Every other surface wraps it — .setmark in a title, .id in a row, .foldbox in
// the selector — so the bug was invisible until the one unwrapped case shipped.
// That makes it a CLASS, not an incident, so this checks every eye a page draws
// rather than the heading that was reported.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');
const ROUTES = ["#/c/orem", "#/c/orem/f/0", "#/c/orem/f/1", "#/c/orem/11", "#/c/orem/map"];

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await page.setViewport({width: 1280, height: 900});

  let total = 0;
  for (const r of ROUTES) {
    await page.goto(PAGE + r, {waitUntil: 'networkidle0'});
    await new Promise(z => setTimeout(z, 800));
    const eyes = await page.evaluate(() => {
      /* AN SVG INSIDE ANOTHER SVG IS NOT THIS BUG: the map draws its own, in a
         coordinate system where `display` means nothing. Only the eyes laid out
         by CSS are in scope. */
      /* THE TEST IS WHETHER IT BREAKS THE LINE, not what `display` says. A
         correctly wrapped eye IS display:block — the reset still applies to the
         <svg>; what fixes it is the inline-flex span around it, so an eye that
         fills its own tight wrapper is right and one that pushes its neighbour
         onto another row is wrong. An earlier version compared the eye's width
         to its parent's and failed on every correct case. */
      const rowOf = e => {
        const host = e.closest("h1,h2,h3,p,li,td,button,a,.crow,.id,.t") || e.parentElement;
        const er = e.getBoundingClientRect();
        // the nearest text that shares the eye's box: does it sit beside it?
        const walk = document.createTreeWalker(host, NodeFilter.SHOW_TEXT);
        let n, best = null;
        while ((n = walk.nextNode())) {
          if (!n.nodeValue.trim()) continue;
          const rg = document.createRange(); rg.selectNodeContents(n);
          const tr = rg.getBoundingClientRect();
          if (tr.width && (best === null || tr.x < best.x)) best = tr;
        }
        return {er, tr: best};
      };
      return [...document.querySelectorAll(".eye")]
        .filter(e => !e.closest("svg.mapsvg"))
        .map(e => {
          const p = e.parentElement;
          const {er, tr} = rowOf(e);
          return {display: getComputedStyle(e).display,
                  wrap: p ? (p.className.baseVal !== undefined ? p.className.baseVal : String(p.className)) : "",
                  parentTag: p ? p.tagName : "",
                  // no text beside it (a bare icon) is fine; text on another row is not
                  breaksLine: tr ? Math.abs(er.y - tr.y) > er.height * 0.75 : false};
        });
    });
    total += eyes.length;
    const blocky = eyes.filter(e => e.breaksLine);
    ok(`${r}: every eye stays in its line`, blocky.length === 0,
       JSON.stringify(blocky.slice(0, 2)));
  }
  ok("the pages actually drew some eyes", total > 0, String(total));

  /* THE HEADING THAT WAS REPORTED, measured as the reader saw it: the eye above
     the name made an 80px h1 out of a 40px one. Height, not just "same line",
     because a heading that wraps for any other reason is the same defect. */
  await page.goto(PAGE + "#/c/orem/f/0", {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 800));
  const head = await page.evaluate(() => {
    const h = document.querySelector("h1.page-h"), eye = h.querySelector(".eye");
    const er = eye.getBoundingClientRect();
    const rg = document.createRange();
    const tn = [...h.childNodes].find(n => n.nodeType === 3 && n.nodeValue.trim());
    rg.selectNodeContents(tn);
    const tr = rg.getBoundingClientRect();
    return {h: Math.round(h.getBoundingClientRect().height),
            wrapped: !!eye.closest(".setmark"),
            gap: Math.round(Math.abs(er.y - tr.y)), eyeH: Math.round(er.height)};
  });
  ok("the set page's eye and its name share a line",
     head.gap < head.eyeH * 0.6, JSON.stringify(head));
  ok("...so the heading is one line tall", head.h < 60, JSON.stringify(head));
  ok("...and the eye is wrapped, like every other one", head.wrapped, JSON.stringify(head));

  /* A SET PAGE OFFERS A WAY TO ACT. It listed a set's claims and stopped, so a
     reader who had just read three claims on one subject and wanted to file a
     fourth had to find their way back to the court first. Asked for.
     AND IT DOES NOT PROMISE THE SET. AddToFolder is moderator-only and no
     OpenClaim variant takes a set, so a claim opened here lands in the court's
     docket and a moderator files it. A button reading "file a claim in this set"
     would name an outcome the chain will not deliver — and the reader would
     learn that after paying for the claim. */
  for (const r of ["#/c/orem/f/0", "#/c/orem/f/1"]) {
    await page.goto(PAGE + r, {waitUntil: 'networkidle0'});
    await new Promise(z => setTimeout(z, 800));
    const act = await page.evaluate(() => {
      const a = document.querySelector(".main .actions");
      if (!a) return {none: true};
      const b = a.querySelector(".btn");
      const sec = a.closest("section");
      const dk = sec ? sec.querySelector(".docket, .empty") : null;
      return {label: b ? b.textContent.trim() : null,
              fn: b ? (b.dataset.fn || b.getAttribute("data-fn")) : null,
              // it belongs under the list, not above it
              belowList: dk ? dk.getBoundingClientRect().bottom <= a.getBoundingClientRect().top + 2 : null};
    });
    ok(`${r}: the set page offers a way to file a claim`, !act.none && /Open a claim/.test(act.label || ""),
       JSON.stringify(act));
    /* THE RULE, NOT THE PROSE. Where a claim lands depends on the set: a
       chain-backed one takes a folderID and the claim opens filed in it, while a
       locally curated one cannot, and the claim opens in the court for a
       moderator to file. Both are honest and the wording is still moving, so what
       is pinned is that the note SAYS where it lands — an earlier version pinned
       one sentence and failed the moment the better branch arrived. */
    ok(`${r}: ...and says where the claim will land`,
       /opens (filed )?in \S+/.test(act.label || ""), JSON.stringify(act.label));
    /* AND NEVER PROMISES THE SET IT CANNOT DELIVER. A local set has no folderID
       to file into; a button saying otherwise names an outcome the chain will not
       produce, and the reader finds out after paying for the claim. */
    ok(`${r}: ...without promising a filing it cannot make`,
       !/(file|filed) (a claim )?(in|into) this set/i.test(act.label || ""), JSON.stringify(act.label));
    ok(`${r}: ...sitting under the list it belongs to`, act.belowList === true, JSON.stringify(act));
  }

  /* THE SIGNAL RIDES THE SENTENCE. It sat in a column of its own on the right —
     sparkline over figure over caption — which read as a second subject: the
     verdict oval ended the title and the figure belonging to it was an inch away.
     Asked for as "(NO) 49% ~ all inline", and that is the shape asserted: the
     oval, the figure and the line on one baseline, in that order.
     ON ledger, NOT orem: the rule underneath is "the figure is the decided
     side's", and orem's visible docket has no settled-NO row to break — mutants
     that severed the plumbing survived against it, all silently correct on a
     court where every verdict is YES. */
  await page.goto(PAGE + "#/c/ledger", {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1500));
  const sig = await page.evaluate(() => {
    const rows = [...document.querySelectorAll(".docket .crow.claimrow")];
    const runs = rows.map(r => ({r, g: r.querySelector(".sig"), o: r.querySelector(".sidetag")}))
                     .filter(x => x.g && x.g.querySelector("b"));
    if (!runs.length) return {none: true};
    const cs = getComputedStyle(runs[0].g);
    /* THE ROW'S OWN OVAL, not the data-side the run carries: that attribute is
       half the mechanism under test, so comparing the caption to it passes when
       both are dropped together. The oval is built by another function. */
    const side = x => { const t = x.o ? x.o.textContent.trim() : ""; return t === "YES" || t === "NO" ? t : ""; };
    const decided = runs.filter(side);
    /* CENTRES, NOT TOPS. The oval is a padded pill and the run is bare text, so
       two boxes on the same line of type have tops that differ by the padding —
       comparing tops called every correct row a break. */
    const inLine = x => {
      const a = x.o.getBoundingClientRect(), b = x.g.getBoundingClientRect();
      const mid = r => r.top + r.height / 2;
      return Math.abs(mid(a) - mid(b)) < Math.max(a.height, b.height) * 0.6 && b.left >= a.left;
    };
    return {n: runs.length, decided: decided.length,
            no: decided.filter(x => side(x) === "NO").length,
            display: cs.display, inTitle: !!runs[0].g.closest(".t"),
            // the caption is dropped where the oval already named the side
            captioned: decided.filter(x => x.g.querySelector("small")).length,
            beside: decided.filter(inLine).length,
            // and the figure is read from the side the court decided
            wrong: decided.filter(x => {
              const b = x.g.querySelector("b").textContent;
              const cap = (x.g.querySelector("small") || {}).textContent || "";
              return cap && !cap.includes("staked " + side(x));
            }).length,
            // the figure stands alone in the row — no side spelled out beside it
            open: runs.filter(x => !side(x)).length,
            worded: runs.filter(x => /staked|YES|NO/.test(x.g.textContent)).length,
            // ...and says which side it is on where a reader can ask
            titled: runs.filter(x => {
              const f = x.g.querySelector("b"), t = f && f.getAttribute("title");
              return t && new RegExp("sits on " + (side(x) || "YES") + "$").test(t);
            }).length,
            // and the figure leads, the line trails it — "(NO) 46.9% ~", as asked
            sparked: runs.filter(x => x.g.querySelector("svg")).length,
            figFirst: runs.filter(x => {
              const b = x.g.querySelector("b"), v = x.g.querySelector("svg");
              return b && v && b.getBoundingClientRect().left < v.getBoundingClientRect().left;
            }).length,
            sample: runs.slice(0, 2).map(x => (x.o ? x.o.textContent.trim() + " " : "") + x.g.textContent.trim())};
  });
  ok("the docket's signal is one inline run", !sig.none && /inline/.test(sig.display),
     JSON.stringify(sig));
  ok("...sitting in the sentence, not a column of its own", sig.inTitle === true, JSON.stringify(sig));
  ok("...the court has a decided NO row to test against", sig.no > 0, JSON.stringify(sig));
  ok("...the figure sits beside its oval on one line", sig.decided > 0 && sig.beside === sig.decided,
     JSON.stringify(sig));
  /* NO CAPTION WHERE THE OVAL SAID IT. "(NO) 46.9% staked NO" says NO twice in
     four words; the oval is the side and the figure is its share. */
  ok("...and does not name the side the oval just named", sig.captioned === 0, JSON.stringify(sig));
  ok("...while every figure still reads from its row's verdict", sig.wrong === 0, JSON.stringify(sig));
  /* THE FIGURE STANDS ALONE, the owner's call: a percentage on a docket is the
     YES share unless a verdict moved it, and the row does not restate a
     convention the whole page keeps.
     THE SUBJECT MOVED RATHER THAN LEAVING, which is the half worth testing. An
     unanswered claim holds stake on both sides, so the bare number IS a choice of
     side; it is named on the figure where a reader can ask for it and a screen
     reader gets it regardless. */
  ok("...with no side spelled out beside the figure", sig.worded === 0, JSON.stringify(sig));
  ok("...but every figure says which side it is on when asked",
     sig.open > 0 && sig.titled === sig.n, JSON.stringify(sig));
  /* FIGURE, THEN LINE — the shape asked for. The line is the history behind the
     number; leading with it puts a 44px graphic between the oval and the figure
     it belongs to. */
  ok("...the line trails the figure rather than leading it",
     sig.sparked > 0 && sig.figFirst === sig.sparked, JSON.stringify(sig));

  /* THE DOCKET SAYS "ANSWERED" ONE WAY. A posted answer whose settle window is
     still open wore a "PROPOSED YES" pill on the meta line while a disputed one
     an inch above wore the oval — the same fact, two vocabularies, in the list a
     reader meets a court in. The map has always drawn oval + `…` for it.
     ON orem, which has both a pending row and a settled one. */
  await page.goto(PAGE + "#/c/orem", {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1500));
  const marks = await page.evaluate(() => {
    const rows = [...document.querySelectorAll(".docket .crow.claimrow")];
    const read = r => ({oval: (r.querySelector(".sidetag") || {}).textContent || "",
                        mark: (r.querySelector(".vqm") || {}).textContent || "",
                        pill: (r.querySelector(".rowpill") || {}).textContent || "",
                        struck: !!r.querySelector("s")});
    const all = rows.map(read);
    return {n: all.length,
            pending: all.filter(x => x.mark === "\u2026").length,
            // a row that knows its side never falls back to a phase pill
            both: all.filter(x => x.oval && x.pill).length,
            // and a pill that names a side is the fallback this replaced
            sidedPill: all.filter(x => !x.oval && /\b(YES|NO)\b/.test(x.pill)).length,
            struckUnmarked: all.filter(x => x.struck && x.mark).length,
            sample: all.filter(x => x.oval).slice(0, 3)};
  });
  ok("a posted answer wears the oval and the clock, as the map draws it",
     marks.pending > 0, JSON.stringify(marks));
  ok("...and never a phase pill beside it", marks.both === 0, JSON.stringify(marks));
  ok("...so no row states its side in a pill instead", marks.sidedPill === 0, JSON.stringify(marks));
  /* A MARKED NO IS NOT STRUCK: the strike says "no longer accurate", which is the
     court's last word, and a clock still running is not one. */
  ok("...and a marked answer is never struck through", marks.struckUnmarked === 0, JSON.stringify(marks));

  /* A CLAIM THAT DIED IS NOT A CHIP. "never answered" is not a state anybody
     chose and not one you can act on — it is how the row ends — so it reads as
     the sentence the rest of the meta line is written in, not as a pill in the
     vocabulary of OPEN and PROPOSED, which are things happening. Asked for.
     THE WORDS STAY. They are the only thing on the row saying the claim is over:
     without them a dead claim in Recently settled is an open one with no clock,
     which reads as settled-somehow when it was never answered at all. */
  const dead = await page.evaluate(() => {
    const rows = [...document.querySelectorAll(".docket .crow.claimrow")]
      .filter(r => /never answered|no decision/.test(r.textContent));
    return {n: rows.length,
            chipped: rows.filter(r => r.querySelector(".rowpill")).length,
            worded: rows.filter(r => [...r.querySelectorAll(".m")]
              .some(m => !m.classList.contains("rowpill")
                      && /^(never answered|no decision)$/.test(m.textContent.trim()))).length};
  });
  ok("a claim that died says so in words, not in a chip",
     dead.n > 0 && dead.chipped === 0, JSON.stringify(dead));
  ok("...and still says it", dead.worded === dead.n, JSON.stringify(dead));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
