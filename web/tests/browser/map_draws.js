// The map actually DRAWS — nodes on screen, not an empty frame.
//
// WHY THIS EXISTS. "The map is shown" was verified three ways that all passed
// while proving nothing about pixels: the realm answers FolderTree, the overlay's
// parser accepts that string, and check-live-reads says every read returns a
// parseable shape. None of them renders anything. The map is built client-side
// from folders and claims, so every one of those can be green while the SVG comes
// out empty — and an empty map looks exactly like a court with nothing in it,
// which is the worst shape of failure because nothing suggests where to look.
//
// DEMO MODE, deliberately. The dataset ships in the file, so this runs anywhere
// with no node and no network — and the demo court is the one a first-time
// visitor lands on.
//
// WHAT THIS DOES NOT COVER, stated because the first version of this comment
// claimed otherwise. The live FolderTree path is NOT exercised here: in demo mode
// the folders come from the shipped dataset and chainFolders is never called.
// Measured — breaking the parser to demand four colon-separated fields left this
// check ALL PASS, because it never runs that code. So the two guards are
// complementary and neither subsumes the other:
//
//   check-web-constants   the realm's row width vs the parser's, by source
//   this check            that a map with data in it reaches the screen
//
// A live-chain variant would be a third, with a different failure mode again —
// the chain being empty is not a bug in the map.
//
// Ablated on the paths demo mode DOES take: renaming .mapwrap fails the first
// three assertions, and returning an empty <svg> from mapSvg fails the node and
// label counts. Those are the two ways the frame can be there and the map not.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1400, height: 1100});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // Find a court from the directory rather than hardcoding one: a slug written
  // into this file is the kind of thing that outlives the dataset it named.
  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 800));
  const slug = await page.evaluate(() => {
    const a = [...document.querySelectorAll('a[href^="#/c/"]')]
      .map(x => x.getAttribute('href'))
      .map(h => (h.match(/^#\/c\/([a-z0-9-]+)$/) || [])[1])
      .find(Boolean);
    return a || null;
  });
  ok("the directory offers a court to open", !!slug, slug ? "slug=" + slug : "none found");
  if (!slug) { await browser.close(); process.exit(1); }

  await page.evaluate(s => { location.hash = "/c/" + s + "/map"; }, slug);
  await new Promise(r => setTimeout(r, 1400));

  const m = await page.evaluate(() => {
    // .mapwrap svg AND NOTHING ELSE. The first version ended its selector list
    // with a bare `svg`, which matched an inline ICON — a 30x32 box with no text
    // in it — so the check measured a glyph and reported the map as undersized
    // and unlabelled while the map itself was fine. The overlay's own CSS says
    // where the map lives: `.mapwrap svg{width:100%;height:100%}`.
    const svg = document.querySelector('.mapwrap svg');
    if (!svg) return {svg: false};
    const r = svg.getBoundingClientRect();
    // Nodes are what a reader sees. Counted by the shapes the map emits rather
    // than by a class name, so a rename does not read as an empty map.
    const shapes = svg.querySelectorAll('circle, rect, path, g[data-claim], g[data-folder]');
    const texts = svg.querySelectorAll('text');
    return {svg: true, w: Math.round(r.width), h: Math.round(r.height),
            shapes: shapes.length, texts: texts.length,
            html: (document.getElementById('main') || {}).innerHTML ? "" : "no #main"};
  });

  ok("the map route renders an svg", m.svg === true);
  ok("...with real size on screen", m.svg && m.w > 200 && m.h > 150,
     m.svg ? `${m.w}x${m.h}` : "");
  // THE ASSERTION THAT MATTERS. An empty frame satisfies everything above.
  ok("...and it is not empty — it has nodes in it", (m.shapes || 0) >= 3,
     `shapes=${m.shapes} texts=${m.texts}`);
  ok("...and the nodes are labelled", (m.texts || 0) >= 1, `texts=${m.texts}`);

  /* THE VERDICT'S MARKS, PAINTED. A settled claim's node wears the oval the claim
     title wears and is struck through when the court ruled NO, and both of those
     are things web/tests/map_test.js can only read as strings: under node there
     is no stylesheet, so a hue that resolves to nothing and a rule the browser
     declines to draw both read as present there.
     RENDERED FROM A FIXTURE, not found on the demo map, because the demo court's
     one settled claim is a YES (`phase:"settled", verdict:0`) — so no strike
     exists on any page this check could navigate to, and the CSS for it would
     ship unexercised. The fixture is map_test.js's, and it is appended INSIDE
     .mapwrap so the map's own rules apply to it exactly as they do to the real
     one.
     Ablated, and each fires on the arm named: dropping `stroke` from .mstrike
     leaves it `none` — SVG's initial value, so the rule is not merely the wrong
     colour, there is no line at all — and fails the hue arm; giving .mvtag a
     fill fails the hairline arm; adding .mvtag to the `far` rule fails the
     zoomed-out arm; striking from the node's padding instead of the title's
     offset fails the crosses-the-sentence arm at x, 16px short.
     THE FILL ABLATION MOVED. It used to be "giving .mvtag a fill fails the
     hairline arm", which stopped being true when the oval left the frame: it is
     filled now, with the node's own surface, so the border it straddles does not
     run through the word. Giving it the SIDE's hue is the ablation that fires. */
  const v = await page.evaluate(() => {
    try {
      const st = t => t + " — every stake withdraws 1×";
      const d = {folders: [{name: "F", claims: [1, 2, 3], folders: [], path: "0"}], all: [1, 2, 3],
                 claims: {1: {title: "The record does not bear this out.", statusText: st("settled NO")},
                          2: {title: "Settled for.", statusText: st("settled YES")},
                          3: {title: "Still open.", statusText: "open — stake YES or NO"}},
                 relations: [], courtName: "C", linkFolders: true};
      const host = document.createElement('div');
      host.innerHTML = mapSvg(mapLayout(d, "titles"), d, "covid");
      document.querySelector('.mapwrap').appendChild(host);
      const svg = host.querySelector('svg.mapsvg');
      const q = s => svg.querySelector(s);
      const line = q('line.mstrike[data-owner="c1"]'), ring = q('rect.mvtag[data-owner="c1"]');
      const word = q('text.mvt[data-owner="c1"]'), ttl = q('text.mtitle[data-owner="c1"]');
      // The tokens resolved by the page, not copied into this file: a hue
      // written here would pass after somebody changes --no.
      const probe = t => { const p = document.createElement('span');
        p.style.color = "var(" + t + ")"; document.body.appendChild(p);
        const c = getComputedStyle(p).color; p.remove(); return c; };
      const box = e => { const b = e.getBBox(); return {x: b.x, y: b.y, w: b.width, h: b.height}; };
      const out = {no: probe("--no"), yes: probe("--yes"), surface: probe("--surface"),
                   found: !!(line && ring && word && ttl)};
      if (out.found) {
        out.line = {stroke: getComputedStyle(line).stroke, display: getComputedStyle(line).display,
                    ...box(line)};
        out.ring = {stroke: getComputedStyle(ring).stroke, fill: getComputedStyle(ring).fill};
        out.word = {fill: getComputedStyle(word).fill, t: word.textContent};
        out.ttl = box(ttl);
        out.yesRing = getComputedStyle(q('rect.mvtag[data-owner="c2"]')).stroke;
        out.strikesOnYes = svg.querySelectorAll('line.mstrike[data-owner="c2"]').length;
        // What survives the zoomed-out view, which hides the sentences.
        svg.classList.add('far');
        out.far = {strike: getComputedStyle(line).display, title: getComputedStyle(ttl).display,
                   ring: getComputedStyle(ring).display, word: getComputedStyle(word).display};
        svg.classList.remove('far');
      }
      host.remove();
      return out;
    } catch (e) { return {err: String(e).slice(0, 160)}; }
  });
  ok("a settled node's verdict marks are in the drawing", v.found === true, v.err || "");
  if (v.found) {
    ok("the strike is painted, not just emitted",
       v.line.display !== "none" && v.line.w > 4, `display=${v.line.display} w=${v.line.w}`);
    ok("...in the losing side's hue, not in ink",
       v.line.stroke === v.no, `${v.line.stroke} vs --no ${v.no}`);
    ok("...and it crosses the sentence it strikes", (() => {
       const l = v.line, t = v.ttl;
       return Math.abs(l.x - t.x) <= 1.5            // starts at the title, not the id
         && (l.x + l.w) >= t.x + t.w * 0.9          // and runs the length of it
         && l.y > t.y && l.y < t.y + t.h;           // through the glyphs, not under them
    })(), `strike ${v.line.x}+${v.line.w}@${v.line.y} title ${v.ttl.x}+${v.ttl.w}@${v.ttl.y}..${v.ttl.y + v.ttl.h}`);
    /* A RING, NOT A CHIP — and that is a claim about the HUE, not about there
       being no fill at all. It used to be fill:none, which was the same thing
       while the oval sat inside the frame. It hangs off the bottom-right corner
       now, straddling the border, and an unfilled ring lets that 1px line run
       through the middle of the word — so it is filled with the NODE'S OWN
       surface, which paints out the border and adds no colour of its own.
       What must never happen is the side's hue as a fill: that is the chip this
       check was written against, a solid red or green pill shouting the verdict
       at the same weight as the sentence. */
    ok("the oval is a hairline ring, not a chip",
       v.ring.stroke === v.no && v.ring.fill !== v.no
       && (v.ring.fill === "none" || v.ring.fill === v.surface),
       `fill=${v.ring.fill} stroke=${v.ring.stroke} surface=${v.surface}`);
    ok("...with the side inside it, in the same hue",
       v.word.t === "NO" && v.word.fill === v.no, `"${v.word.t}" ${v.word.fill}`);
    ok("a settled YES rings in green and keeps its sentence",
       v.yesRing === v.yes && v.strikesOnYes === 0, `${v.yesRing} strikes=${v.strikesOnYes}`);
    ok("zoomed out, the sentence and its strike go and the verdict stays",
       v.far.title === "none" && v.far.strike === "none"
       && v.far.ring !== "none" && v.far.word !== "none", JSON.stringify(v.far));
  }

  /* ONE RING ON THE FOCUSED NODE, NOT TWO.
     Arriving at ?focus=N marks the node .focused, selects it and gives it DOM
     focus, so it drew its own 3px accent stroke AND the global :focus-visible
     outline 2px outside that — the same colour, one border around the other.
     Reported from the live map; it "went away" on the next click only because the
     click moved focus.
     A COMPUTED-STYLE FACT, invisible to any source check: both rings are real CSS
     applying to the same element, and only a laid-out page with focus somewhere
     can say whether both are on. The pair is asserted — outline gone AND the
     node's own stroke still there — because "no outline" alone would also pass on
     a node with no focus indication at all. */
  {
    const id = await page.evaluate(() => {
      const a = document.querySelector('a.mnode-a[data-id]');
      return a ? a.getAttribute('data-id') : null;
    });
    if (id) {
      await page.evaluate((s, i) => { location.hash = `/c/${s}/map?focus=${i}`; }, slug, id);
      await new Promise(r => setTimeout(r, 1400));
      const f = await page.evaluate(i => {
        const a = document.querySelector(`a.mnode-a[data-id="${i}"]`);
        if (!a) return null;
        const cs = getComputedStyle(a);
        const rect = a.querySelector('.mnode');
        return {cls: a.getAttribute('class'), focused: document.activeElement === a,
                outline: cs.outlineStyle, width: cs.outlineWidth,
                stroke: rect ? getComputedStyle(rect).strokeWidth : null};
      }, id);
      ok("the focus target is marked and holds focus",
         f && /focused|selected/.test(f.cls), JSON.stringify(f));
      ok("...with no outline around its own ring", f && f.outline === "none", JSON.stringify(f));
      ok("...and that ring is still drawn", f && parseFloat(f.stroke) >= 3, JSON.stringify(f));
      // And an ordinary node still gets the standard ring, or this fix has taken
      // the keyboard's focus indicator with it.
      const plain = await page.evaluate(() => {
        const a = [...document.querySelectorAll('a.mnode-a')]
          .find(x => !/focused|selected/.test(x.getAttribute('class') || ''));
        if (!a) return null;
        a.focus();
        const cs = getComputedStyle(a);
        return {outline: cs.outlineStyle, width: cs.outlineWidth};
      });
      ok("an unselected node keeps the standard focus ring",
         plain && plain.outline === "solid" && parseFloat(plain.width) >= 2, JSON.stringify(plain));
    }
  }

  /* EVERY BADGE SAYS WHAT IT MEANS ON HOVER. `!` is the answer that went against
     the stake, and it was written down in exactly two places a reader has to
     already be looking for: the legend at the foot of the map, and the card
     behind a click. Reported — hovering the mark itself said nothing.
     THE TITLE HANGS ON THE GROUP, not on the pill's rect: the glyph is drawn
     over that rect and takes the pointer, so a title on the rect alone leaves a
     hole in the tooltip directly over the mark being pointed at. */
  const said = await page.evaluate(() => {
    const gs = [...document.querySelectorAll("#mapbox g.vsay")];
    const badges = [...document.querySelectorAll("#mapbox .mvtag")];
    return {groups: gs.length, badges: badges.length,
            titled: gs.filter(g => (g.querySelector("title") || {}).textContent).length,
            loose: badges.filter(r => !r.closest("g.vsay")).length,
            // the mark this was reported about, from the function that draws it
            bang: mapMarkWords({short: "settled", side: "NO"}, {inst: 72, route: "vote"}, "mark"),
            oval: mapMarkWords({short: "settled", side: "NO"}, {inst: 72, route: "vote"}, "side"),
            card: mapMarkWords({short: "settled", side: "NO"}, {inst: 72, route: "vote"}),
            // and a pair drawn on the page: the two pills of one badge
            pair: (() => {
              const g = gs.find(x => x.parentElement && [...x.parentElement.querySelectorAll("g.vsay")].length > 1);
              if (!g) return null;
              const two = [...g.parentElement.querySelectorAll("g.vsay")].slice(0, 2);
              return two.map(x => ({mark: x.querySelector("text").textContent,
                                    say: x.querySelector("title").textContent}));
            })()};
  });
  ok("the map draws verdict badges", said.groups > 0, JSON.stringify(said));
  ok("...every one of them carries its sentence", said.titled === said.groups, JSON.stringify(said));
  ok("...and no badge is left without one", said.loose === 0, JSON.stringify(said));
  ok("the `!` mark explains that the verdict went against the stake",
     /went against the stake/.test(said.bang || ""), JSON.stringify(said.bang));
  ok("...and says which way the stake sat", /\b72% the other way/.test(said.bang || ""),
     JSON.stringify(said.bang));
  /* THE OVAL AND THE MARK ARE DIFFERENT QUESTIONS. Both bubbles used to hand
     over the same paragraph, so hovering `!` explained the verdict instead of
     the glyph under the pointer. */
  ok("...while the oval beside it says what was decided",
     /settled this NO/.test(said.oval || ""), JSON.stringify(said.oval));
  ok("...and does not repeat the mark's sentence",
     !/against the stake/.test(said.oval || ""), JSON.stringify(said.oval));
  ok("...so the two are not the same string", said.bang !== said.oval,
     JSON.stringify([said.bang, said.oval]));
  /* The card behind a click still gets both, from the same clauses — the whole
     point of building them in one place. */
  ok("the card still carries verdict and mark together",
     /settled this NO/.test(said.card || "") && /against the stake/.test(said.card || ""),
     JSON.stringify(said.card));
  if (said.pair) ok("a badge's two pills differ on the page too",
     said.pair[0].say !== said.pair[1].say, JSON.stringify(said.pair));

  /* A CLAIM THAT BECAME A SET IS DRAWN AS THE SET, here too. The map drew both —
     a box named for the claim beside the folder that claim had just created — and
     the two are one object. The docket stopped drawing the second; this is the
     other surface the duplicate was reported on.
     ON annex, the only court whose offline sample has a claim-born set. */
  await page.goto(PAGE + '#/c/annex/map', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 4200));
  const setborn = await page.evaluate(() => {
    const ids = [...document.querySelectorAll('#mapbox a[data-id]')].map(a => a.dataset.id);
    // what the court page says was affirmed, read from the same demo data
    const born = (typeof DEMO_OVERLAY !== "undefined")
      ? (DEMO_OVERLAY.courts.annex.folders || []).map(f => f.born).filter(Boolean).map(String)
      : [];
    return {ids, born, drawn: born.filter(b => ids.includes(b)),
            folders: document.querySelectorAll('#mapbox a[data-fid]').length};
  });
  ok("the map has a claim-born set to test against",
     setborn.born.length > 0 && setborn.folders > 0, JSON.stringify(setborn));
  ok("...and the claim that made it is not a node of its own",
     setborn.drawn.length === 0, JSON.stringify(setborn));
  /* AND THE REST STILL DRAW. Suppressing every claim would satisfy the line
     above and leave an empty map, which is the failure that reads as success. */
  ok("...while the court's other claims still do", setborn.ids.length > 0, JSON.stringify(setborn.ids));

  /* THE SET MARK IS GEOMETRY ON THE MAP, not a character in the text. In HTML
     setMarkHtml swaps U+13080 for the drawn eye; an SVG <text> has no span to
     swap into, so the codepoint reached the drawing raw — a tofu box in front of
     the sentence for a reader with no hieroglyph font, on the surface hardest to
     zoom into. Asserted as: no codepoint anywhere in the SVG, and a .mset drawn
     instead.
     TWO PLACES, ONE MARK, and which one depends on whether the court agreed
     yet. An unborn heading is still a claim, so it is a NODE and wears the mark
     beside its id. A born one is not drawn as a claim at all — mapSvg's own note
     calls a set and the claim it came from "one object shown twice" and drops
     the node — so its mark belongs on the BOX. Both are checked, because either
     alone would pass with the other missing.
     Ablated: dropping the folder arm leaves onFolders 0; dropping the strip
     leaves rawAnywhere true while the marks still draw, which is the failure
     that looks fine in a screenshot and is a tofu on a stranger's machine. */
  const setmark = await page.evaluate(() => {
    try {
      const M = "\u{13080}", st = t => t + " — every stake withdraws 1×";
      /* A LONG NAME ON PURPOSE, because a short one cannot fail the way this
         drawing fails. The mark sits INSIDE the box, so the box has to be grown
         by the width it takes or the name is truncated to fit around it — and
         truncation is invisible to markOverlapsLabel, which only ever sees two
         rects that do not touch. "Origins" fitted either way and proved nothing. */
      const d = {folders: [{name: "Vaccine safety claims", claims: [1, 2], folders: [], path: "0", born: 3}],
                 all: [1, 2, 3],
                 claims: {1: {title: "An ordinary claim.", statusText: st("settled YES")},
                          2: {title: M + " Furin cleavage site", statusText: st("settled YES")},
                          3: {title: M + " Vaccine safety claims", statusText: st("settled YES")}},
                 relations: [], courtName: "C", linkFolders: true};
      const host = document.createElement('div');
      host.innerHTML = mapSvg(mapLayout(d, "titles"), d, "covid");
      document.querySelector('.mapwrap').appendChild(host);
      const svg = host.querySelector('svg.mapsvg');
      const out = {marks: svg.querySelectorAll('.mset').length,
                   onClaim: svg.querySelectorAll('.mset[data-owner]').length,
                   onFolder: svg.querySelectorAll('.mset[data-fid]').length,
                   raw: svg.textContent.includes(M),
                   nameKept: svg.textContent.includes("Furin cleavage site"),
                   ordinary: svg.querySelectorAll('.mset[data-owner="c1"]').length,
                   // Every word of the folder's name, or the box was sized for a
                   // label it then had to indent past its own right edge.
                   folderLabel: [...svg.querySelectorAll('.mhdr-t[data-owner="h0"]')]
                                  .map(t => t.textContent).join(" ")};
      /* INSIDE THE BOX, AND STILL NOT ON THE NAME. Both halves are measured
         because each one alone has been satisfied by a broken drawing. An early
         version put the mark inside at the top-left — exactly where a
         left-aligned, vertically centred label begins — so the eye landed on the
         first letter and read as part of the word, and every count-based
         assertion above passed while that was true. The fix moved it OUT to
         straddle the border, which cleared the name and then read as a smudge on
         the edge rather than as something the node was saying.
         What holds now is both at once: the mark sits within the rect, and the
         box was GROWN by mapSetMark's lead so the name has room beside it. Drop
         the lead from mapFolderSize and the label truncates rather than
         overlapping — which markOverlapsLabel cannot catch, since it only ever
         sees two rects that do not touch — so folderLabel asserts the name
         intact. MEASURED: with the fixture's folder named "Origins" that arm
         passed against a mapFolderSize that reserved nothing at all. */
      const mk = svg.querySelector('.mset[data-fid]'), bx = svg.querySelector('.mfold');
      if (mk && bx) {
        const m = mk.getBoundingClientRect(), r = bx.getBoundingClientRect();
        out.markOverlapsLabel = [...svg.querySelectorAll('.mhdr-t')].some(t => {
          const q = t.getBoundingClientRect();
          return !(m.right < q.left || m.left > q.right || m.bottom < q.top || m.top > q.bottom);
        });
        // Crosses the corner: some of it out, some of it in. Both halves, or a
        // mark drawn wholly outside satisfies "not inside" and a mark drawn
        // wholly inside satisfies "not outside".
        out.markStraddles = m.left < r.left && m.top < r.top
                         && m.right > r.left && m.bottom > r.top;
        const ring = svg.querySelector('.msetring');
        out.ringed = !!ring;
        /* The ring must be on the same corner the glyph is, or the two drift
           apart at some zoom and the eye sits half out of its own badge.
           MEASURED LOOSELY ON PURPOSE, VERTICALLY. getBoundingClientRect on an
           SVG <text> returns the FONT's line box — ascender to descender —
           not the glyph's ink, and the two do not share a centre: with the
           mark's INK centred exactly on the ring, its line box still reports a
           centre a tenth of an em high. Requiring the line box inside the ring
           was therefore a test of the font's metrics rather than of where the
           mark is drawn, and it went red the moment the ink was centred
           properly. The exact placement is measured in map_reveal.js, against
           rendered pixels; what belongs here is that the badge and the mark are
           on the same corner at all. */
        if (ring) {
          const c = ring.getBoundingClientRect();
          const mid = r0 => r0.top + r0.height / 2;
          out.ringHoldsMark = m.left >= c.left - 1 && m.right <= c.right + 1
                           && Math.abs(mid(m) - mid(c)) < c.height / 3;
        }
      }
      svg.classList.add('far');
      const cm = svg.querySelector('.mset[data-owner]'), fm = svg.querySelector('.mset[data-fid]');
      out.farClaim = cm ? getComputedStyle(cm).display : null;
      out.farFolder = fm ? getComputedStyle(fm).display : null;
      host.remove();
      return out;
    } catch (e) { return {err: String(e).slice(0, 160)}; }
  });
  /* THE CODEPOINT IS THE MARK, INCLUDING HERE. This asserted the opposite — the
     mark drawn as paths and the character gone from the text — because coverage
     was the problem: U+13080 is Supplementary-Plane and a machine with no
     hieroglyph font drew a tofu box. Embedding the single glyph removed that
     reason, and the mark is now the thing a reader can select out of the map and
     paste into a claim title. So the map prints it too, in a <text> that names
     the embedded face. Inverted deliberately: the codepoint MUST be present. */
  ok("the set mark is the character, present in the map's own text",
     setmark.marks === 2 && setmark.raw === true, JSON.stringify(setmark));
  ok("...on the node of a heading the court has not carried yet",
     setmark.onClaim === 1, JSON.stringify(setmark));
  ok("...and on the box of the set a claim became",
     setmark.onFolder === 1, JSON.stringify(setmark));
  ok("...while the name it prefixed survives, and an ordinary claim gets none",
     setmark.nameKept === true && setmark.ordinary === 0, JSON.stringify(setmark));
  /* Zoomed out the sentences go, so a mark that annotated one goes with it —
     the rule .mtitle and .mstrike already follow. A BOX is still drawn and named
     at every zoom, so its mark stays. */
  ok("...and the box grew for it, so the whole name is still drawn",
     /[…]/.test(setmark.folderLabel) === false
       && setmark.folderLabel.replace(/\s+/g, " ").includes("Vaccine safety claims"),
     JSON.stringify({label: setmark.folderLabel}));
  ok("...and the set's mark straddles its corner, clear of its name",
     setmark.markOverlapsLabel === false && setmark.markStraddles === true,
     JSON.stringify({overlap: setmark.markOverlapsLabel, straddles: setmark.markStraddles}));
  /* THE RING IS WHAT MAKES THAT POSITION READABLE, so it is asserted rather than
     left to a screenshot. A mark on a border without one reads as a smudge on
     the edge — which is why it was moved off the border once already — and
     nothing about the glyph's own rect can tell the difference. */
  ok("...enclosed the way the verdict ovals are, and holding the glyph",
     setmark.ringed === true && setmark.ringHoldsMark === true,
     JSON.stringify({ringed: setmark.ringed, holds: setmark.ringHoldsMark}));
  ok("...the claim's mark leaves with the sentences, the set's stays",
     setmark.farClaim === "none" && setmark.farFolder !== "none",
     `claim ${setmark.farClaim}, folder ${setmark.farFolder}`);

  // A page error is a failure even when the frame looks right: the map may have
  // drawn a first pass and thrown on the data.
  /* THE TEMPLE ON THE COURT NODE, measured rather than eyeballed. Three things
     make it part of the node instead of a picture near it, and each has its own
     way of being wrong: it can drift off centre, it can float above the box, and
     it can sit OUTSIDE the group that carries data-court — which would leave a
     pediment that ignores clicks while the box under it selects.
     The path is shared with the inline court icon, so this also fails if the two
     stop being the same building. */
  const temple = await page.evaluate(() => {
    const t = document.querySelector(".mtemple"), c = document.querySelector("rect.mcourt");
    if (!t || !c) return {drawn: !!t, court: !!c};
    /* SCREEN RECTS, NOT getBBox. getBBox on a <g> answers in the group's OWN
       coordinate system — before its transform — so a temple translated onto the
       court's top edge reports y=0,height=12 and every comparison with the box
       is nonsense. Measured in the one space both elements share. */
    const tb = t.getBoundingClientRect(), cb = c.getBoundingClientRect();
    return {
      drawn: true,
      // Its base on the box's top edge, to within a rounding of the transform.
      gap: +(cb.top - tb.bottom).toFixed(2),
      offCentre: +(((tb.left + tb.right) / 2) - ((cb.left + cb.right) / 2)).toFixed(2),
      // Narrower than the heading it stands over, or it is a second heading.
      narrower: tb.width < cb.width,
      inCourtGroup: !!t.closest("[data-court]"),
      // Drawn after the edges, so the spokes radiating from the centre pass under.
      afterEdges: !!t.closest("svg").querySelector(".medge")
        && Array.from(t.closest("svg").children).indexOf(t.closest("[data-court]"))
           > Array.from(t.closest("svg").children).indexOf(
               document.querySelector(".medge").parentElement === t.closest("svg")
                 ? document.querySelector(".medge") : document.querySelector(".medge").closest("svg > *")),
      fill: getComputedStyle(t.querySelector("path")).fill,
    };
  });
  ok("a temple stands on the court node, centred and on its top edge",
     temple.drawn === true && Math.abs(temple.gap) < 1 && Math.abs(temple.offCentre) < 1,
     JSON.stringify(temple));
  ok("...narrower than the heading, inside the court's own group, and inked",
     temple.narrower === true && temple.inCourtGroup === true
       && /rgb|#/.test(temple.fill || ""),
     JSON.stringify(temple));
  ok("...and the edges radiating from the centre pass under it",
     temple.afterEdges === true, JSON.stringify(temple));

  /* THE COMMENT CLUSTER'S CELL IS ON EVERY CLAIM NODE, at the corner outside it.
     Only the CELL is checkable here: filling it reads BoardSize per claim and the
     demo has no chain, so a demo map draws no dots by design. What this asserts is
     the part a live fill depends on — that the group exists, is inside the node's
     own anchor so it dims with it, and is translated to the bottom-right corner
     rather than into the frame. */
  const cmt = await page.evaluate(() => {
    const gs = [...document.querySelectorAll("svg.mapsvg g.mcmt")];
    const nodes = document.querySelectorAll("svg.mapsvg a.mnode-a").length;
    if (!gs.length) return {groups: 0, nodes};
    const g = gs[0], a = g.closest("a.mnode-a");
    const r = a && a.querySelector("rect.mnode");
    const tr = (g.getAttribute("transform") || "").match(/translate\(([-\d.]+) ([-\d.]+)\)/);
    return {
      groups: gs.length, nodes,
      inNodeAnchor: !!a,
      // the corner it names must be the node's own bottom-right
      /* BOTTOM-CENTRE, and it was bottom-right until a reader said the cluster
         belonged "center bottom dangling out the claim node, because there's
         the most space there". Centred horizontally on the node's own frame,
         and at or below its full height — the node paints a thumbnail row and a
         vote row under the frame, so anchoring at the frame alone started the
         fan inside the node. */
      atBottomCentre: !!(r && tr
        && Math.abs(+tr[1] - (+r.getAttribute("x") + +r.getAttribute("width") / 2)) < 0.6
        && +tr[2] >= +r.getAttribute("y") + +r.getAttribute("height") - 0.6),
      emptyInDemo: gs.every(x => x.children.length === 0),
    };
  });
  ok("every claim node carries a comment-cluster cell", cmt.groups === cmt.nodes && cmt.groups > 0,
     JSON.stringify(cmt));
  ok("...inside the node's own anchor, centred under its bottom edge",
     cmt.inNodeAnchor === true && cmt.atBottomCentre === true, JSON.stringify(cmt));
  /* THE SAMPLE DRAWS THEM NOW, and this assertion used to say the opposite:
     "empty in demo, where there is no chain to count comments". That was true
     of BoardSize and never true of the fixture — DEMO.claims carries each
     board's size and its top-level wire — and while it held, no browser check
     could see a cluster at all. Which is how the thing shipped invisible.
     A CLUSTER SAYS WHAT IT IS. Dots a reader cannot read are decoration; the
     <title> is what makes seven dots "4 comments in 3 threads" on hover, and
     it must be the FIRST child because that is the one a browser shows. */
  /* OREM'S MAP FOR THESE, because annex carries no board fixtures. Only orem/1
     and orem/2 have comments in the sample, so on annex there is nothing to
     draw — and asserting a cluster there would be asserting the shape of the
     sample rather than the behaviour of the code. */
  await page.goto(PAGE + '#/c/orem/map', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1400));
  const cmtSaid = await page.evaluate(() => {
    const filled = [...document.querySelectorAll("g.mcmt")].filter(g => g.children.length);
    return filled.map(g => {
      const t = g.querySelector("title");
      return {id: g.dataset.cmt, dots: g.querySelectorAll("circle.mcmt-d").length,
              titleFirst: !!t && g.firstElementChild === t,
              words: t ? t.textContent : null,
              hidden: g.getAttribute("aria-hidden")};
    });
  });
  // Every sentence commentCountLabel can produce, and nothing else.
  const SAYS = /^\d+ comments?( in \d+ threads?|, none replied to)?$/;
  ok("the sample map draws a cluster for the claims that have comments",
     cmtSaid.length > 0, JSON.stringify(cmtSaid));
  ok("...each one carrying its count in words, as its first child",
     cmtSaid.every(c => c.titleFirst && SAYS.test(String(c.words || "").trim())),
     JSON.stringify(cmtSaid));
  ok("...and the cell no longer calls itself decoration, now that it says something",
     cmtSaid.every(c => c.hidden === null), JSON.stringify(cmtSaid));


  /* AND THE CLUSTER SURVIVES THE ZOOM-OUT, asked of the CASCADE rather than of
     the stylesheet — a source test can read the rule, but only a browser can say
     what a dot computes to once .far is on, which is where a specificity mistake
     would hide.
     THE BUG THIS STANDS OVER. `.mapsvg.far .mcmt{display:none}` followed .mtitle
     and .mthumb on the grounds that a cluster beside every node is noise. But
     only claims that HAVE comments get one, and the zoomed-out view is the one
     where "where is the talking" is the whole question. MEASURED on kourt.xyz at
     1440x900: no zoom showed a cluster at all — on arrival the two commented
     claims sat below a 900px viewport that does not scroll, and one click of FIT
     brought them into view and set .far, which blanked them.
     Demo has no comments, so a cluster is put into a real cell by hand; the CSS
     under test is the page's own. */
  /* MEASURED ON AN UNSELECTED NODE, and the first version of this was not: by
     this point the harness has clicked a claim, and `.mnode-a.selected .mcmt-d`
     is .75 in BOTH states, so near and far read identically and the check said
     nothing. That precedence is deliberate — a picked or hovered node should out-
     rank the zoom, which is why the far rules sit ABOVE the hover rules in the
     stylesheet — so the selection is cleared here rather than worked around. */
  await page.mouse.move(2, 2);
  const far = await page.evaluate(() => {
    document.querySelectorAll("a.mnode-a.selected").forEach(a => a.classList.remove("selected"));
    const cell = [...document.querySelectorAll("g.mcmt")]
      .find(g => !g.closest("a.mnode-a").matches(".selected,:hover"));
    if(!cell) return {err: "no unselected g.mcmt cell to test"};
    cell.innerHTML = '<path class="mcmt-e" d="M4 4L8 8"/><circle class="mcmt-d" cx="6" cy="6" r="1.75"/>';
    const dot = cell.querySelector("circle.mcmt-d"), edge = cell.querySelector("path.mcmt-e");
    const svg = document.querySelector("svg.mapsvg");
    const read = () => ({cell: getComputedStyle(cell).display,
                         dot: getComputedStyle(dot).display,
                         dotOp: +getComputedStyle(dot).opacity,
                         edgeOp: +getComputedStyle(edge).opacity,
                         w: +cell.getBoundingClientRect().width.toFixed(1)});
    svg.classList.remove("far"); const near = read();
    svg.classList.add("far");    const out  = read();
    svg.classList.remove("far"); cell.innerHTML = "";
    return {near, far: out};
  });
  ok("a cluster is still drawn when the map zooms out",
     !far.err && far.far.dot !== "none" && far.far.cell !== "none" && far.far.w > 0,
     JSON.stringify(far));
  ok("...and brighter out there than up close, since it shrinks with the zoom",
     !far.err && far.far.dotOp > far.near.dotOp && far.far.edgeOp > far.near.edgeOp,
     JSON.stringify(far));

  /* THE CARD SAYS IT TOO, which is the surface that was asked for and the one a
     hover tooltip cannot serve — a title vanishes when the pointer moves, and
     the card is where a reader looks after clicking. It reads the map's own
     preload, so it costs no query: a card that fired its own read would spend
     one on every click for a number the map already has. */
  const card = await page.evaluate(async () => {
    const g = [...document.querySelectorAll("g.mcmt")].filter(x => x.children.length)[0];
    if(!g) return {err: "no filled cluster to click"};
    const said = g.querySelector("title").textContent.trim();
    /* CANCELABLE, or this navigates instead of selecting. The node is a real
       <a href="#/c/slug/id">, and the map's handler selects by calling
       preventDefault on the click. A MouseEvent without cancelable:true cannot
       BE prevented, so the browser followed the href, replaced the map with the
       claim page, and the card this asserts on no longer existed — the
       assertion failed against a card that was correct all along. */
    g.closest("a.mnode-a").dispatchEvent(
      new MouseEvent("click", {bubbles: true, cancelable: true}));
    await new Promise(z => setTimeout(z, 500));
    /* #mapsel, an ID and not a class — mountMap holds it with
       getElementById and the class names in the stylesheet are its children
       (.mapsel-h, .mapsel-t). Selecting ".mapsel" found nothing and the card
       assertion failed against a card that was in fact correct. */
    const sel = document.getElementById("mapsel");
    const link = sel && [...sel.querySelectorAll("a.tlink")]
      .find(a => /comment/.test(a.textContent));
    return {said, onCard: link ? link.textContent.replace(/\u2192|→/g, "").trim() : null,
            href: link ? link.getAttribute("href") : null};
  });
  ok("the card repeats what the cluster said, word for word",
     !card.err && card.onCard === card.said, JSON.stringify(card));
  ok("...and it is a link to the board, where the talking actually is",
     !card.err && /\/board$/.test(String(card.href)), JSON.stringify(card));

  /* WHERE THE CLUSTER HANGS, and how big it is. Reported as "i can barely see
     it", with the ask that it belong "center bottom dangling out the claim
     node, because there's the most space there" — which measurement bore out:
     nodes are 230x61 units and the clearance BELOW one is 58 at the tightest,
     178 median, while the old fan hung off the bottom-RIGHT corner into the gap
     beside the node.
     MEASURED AGAINST WHAT THE NODE PAINTS, not against its anchor. The cluster
     lives inside that anchor, so comparing the two is self-referential and
     returns minus the cluster's own height whatever the truth is — which is
     exactly the false reading that sent me looking for an overlap that was not
     there. The comparison here is against every rect, text and image the node
     draws. */
  const fan = await page.evaluate(() => {
    const svg = document.querySelector("svg.mapsvg");
    const gs = [...document.querySelectorAll("g.mcmt")].filter(g => {
      try { return g.getBBox().width > 0; } catch (e) { return false; }
    });
    if (!gs.length) return {none: true};
    return gs.map(g => {
      const id = String(g.dataset.cmt || "").split("-").pop();
      const dot = svg.querySelector(`[data-owner="c${id}"]`);
      const a = dot ? dot.closest("a") : null;
      if (!a) return {id, noOwner: true};
      const painted = [...a.querySelectorAll("rect,text,image")]
        .map(e => e.getBoundingClientRect()).filter(R => R.width > 0 && R.height > 0);
      const bottom = Math.max(...painted.map(R => R.bottom));
      const left = Math.min(...painted.map(R => R.left));
      const right = Math.max(...painted.map(R => R.right));
      const C = g.getBoundingClientRect();
      const others = [...document.querySelectorAll("a.mnode-a")].filter(x => x !== a)
        .map(x => x.getBoundingClientRect());
      return {id,
        clears: +(C.top - bottom).toFixed(1),
        offCentre: +Math.abs((C.left + C.width / 2) - ((left + right) / 2)).toFixed(1),
        w: +C.width.toFixed(1), h: +C.height.toFixed(1),
        insideWidth: C.left >= left - 1 && C.right <= right + 1,
        overlaps: others.filter(R => !(C.right <= R.left || C.left >= R.right ||
                                       C.bottom <= R.top || C.top >= R.bottom)).length};
    });
  });
  ok("the map draws at least one comment cluster to measure", !fan.none,
     JSON.stringify(fan).slice(0, 120));
  if (!fan.none) {
    const bad = fan.filter(f => f.noOwner);
    ok("every cluster is matched to the claim node it belongs to", bad.length === 0,
       JSON.stringify(bad).slice(0, 160));
    const good = fan.filter(f => !f.noOwner);
    ok("every cluster hangs BELOW everything its node paints",
       good.every(f => f.clears >= 0),
       JSON.stringify(good.map(f => [f.id, f.clears])));
    ok("...centred under it, not off a corner",
       good.every(f => f.offCentre <= 1),
       JSON.stringify(good.map(f => [f.id, f.offCentre])));
    ok("...within the node's own width, so it reads as that claim's",
       good.every(f => f.insideWidth),
       JSON.stringify(good.map(f => [f.id, f.insideWidth])));
    ok("...and the cluster spans at least 16px",
       good.every(f => f.w >= 16 && f.h >= 12),
       JSON.stringify(good.map(f => [f.id, f.w, f.h])));
    // The reason the old fan avoided this quadrant. Still checked.
    ok("...without landing on a neighbouring node",
       good.every(f => f.overlaps === 0),
       JSON.stringify(good.map(f => [f.id, f.overlaps])));
  }

  /* THE DOT ITSELF, which is what "i can barely see it" was about. The arm
     above measures the cluster's BOX, and that box is set by the sweep and the
     reach — so shrinking every dot back to the old radius left it entirely
     unmoved and passing. Measured, not assumed: reverting r to 2.1/2.2/2.6
     fired NOTHING until this arm existed. The radius is read off the drawn
     circle, so it is the ink a reader sees rather than a constant in the
     source. 3.0 sits above the old ceiling of 2.6 and below the shipped floor
     of 3.4. */
  const dotR = await page.evaluate(() => {
    const ds = [...document.querySelectorAll("circle.mcmt-d")];
    if (!ds.length) return {none: true};
    const rs = ds.map(d => parseFloat(d.getAttribute("r")) || 0);
    return {min: Math.min(...rs), max: Math.max(...rs), n: rs.length};
  });
  ok("a comment dot is drawn big enough to see", !dotR.none && dotR.min >= 3.0,
     JSON.stringify(dotR));
  /* BOTH ZOOM STATES, because there are two rules and the map is in one of
     them. `.mapsvg.far .mcmt-d` overrides `.mcmt-d`, and this map renders FAR —
     so an arm that reads the computed opacity as-is pins the far rule only, and
     reverting the near rule to its old .42 fired nothing. Measured. The class
     is toggled to read each, and restored either way. */
  const ink = await page.evaluate(() => {
    const svg = document.querySelector("svg.mapsvg");
    if (!svg) return {none: true};
    /* A DOT IN AN UNSELECTED NODE. By this point the harness has clicked a
       claim, and `.mnode-a.selected .mcmt-d` sets .75 — which outranks the base
       rule and made this arm read the SELECTED state. Reverting the base
       opacity to its old .42 then fired nothing, because .42 was never what was
       being measured. Any selected node is skipped, and if every one of them is
       selected the class comes off for the read and goes back after. */
    const dots = [...document.querySelectorAll("circle.mcmt-d")];
    if (!dots.length) return {none: true};
    let d = dots.find(x => { const a = x.closest("a.mnode-a"); return a && !a.classList.contains("selected"); });
    let unselected = null;
    if (!d) { d = dots[0]; unselected = d.closest("a.mnode-a"); unselected && unselected.classList.remove("selected"); }
    const wasFar = svg.classList.contains("far");
    svg.classList.add("far");
    const far = parseFloat(getComputedStyle(d).opacity);
    svg.classList.remove("far");
    const near = parseFloat(getComputedStyle(d).opacity);
    if (wasFar) svg.classList.add("far");
    if (unselected) unselected.classList.add("selected");
    return {near, far, wasFar, hadToDeselect: !!unselected};
  });
  ok("...and the fill is not near-invisible, zoomed in or out",
     !ink.none && ink.near >= 0.55 && ink.far >= 0.7, JSON.stringify(ink));

  ok("no page errors on the map route", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
