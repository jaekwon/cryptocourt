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

  // A page error is a failure even when the frame looks right: the map may have
  // drawn a first pass and thrown on the data.
  ok("no page errors on the map route", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
