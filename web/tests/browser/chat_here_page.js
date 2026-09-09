// THE COUNT IS A LINK, AND WHERE IT GOES SHOWS NOTHING PERSONAL.
//
// Two halves, and the second is the one worth guarding. The panel's count now
// links to a page of presence-by-country — so this checks that the affordance
// exists (underlined under the pointer, not before), and then that the page it
// reaches publishes a distribution and NOT the things that would make it a
// tracking page: no name, no message, no room, no network, and no country with
// a single connection in it.
//
// AND THAT IT READS /api/chat/here RATHER THAN /api/chat/diag. The diagnostics
// payload also reports the site's own answerer — whether it is on, how often it
// has spoken, what it has cost — and pointing readers at that would undo, in one
// devtools tab, the thing this deployment asks for. The endpoint the page calls
// is therefore part of the requirement, so it is asserted.
const {PAGE, demoPage} = require('./harness');

// A floor of two lives in the service, so a one-connection country arrives
// already folded into `elsewhere`. The page must not be able to unfold it.
const HERE = {
  by_country: [{cc: "US", n: 7}, {cc: "DE", n: 3}, {cc: "NO", n: 2}],
  elsewhere: 4,
  networks: 9, rooms: 3, geo_known: true,
};

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  await page.evaluateOnNewDocument((here) => {
    window.__asked = [];
    const real = window.fetch;
    window.fetch = async (url, opt) => {
      const u = String(url);
      window.__asked.push(u);
      if (/\/api\/chat\/here/.test(u)) {
        return new Response(JSON.stringify(here),
          {status: 200, headers: {"Content-Type": "application/json"}});
      }
      if (/\/api\/chat\/health/.test(u)) {
        return new Response(JSON.stringify({ok: true, enforcing: true}),
          {status: 200, headers: {"Content-Type": "application/json"}});
      }
      if (/\/api\/chat\//.test(u)) {
        return new Response(JSON.stringify({
          messages: [{id: 7, moniker: "alice", body: "hello", created_at: 1757000000}],
          next: 8, you: {state: "ok"}, now: 1757000005, here: 14,
        }), {status: 200, headers: {"Content-Type": "application/json"}});
      }
      return real(url, opt);
    };
  }, HERE);

  // ---- the affordance, on the panel ---------------------------------------
  await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1300));

  const link = await page.evaluate(() => {
    const a = document.querySelector(".chathere a");
    if (!a) return null;
    const rest = getComputedStyle(a).textDecorationLine;
    return {href: a.getAttribute("href"), text: a.textContent.trim(), rest};
  });
  ok("the count is a link", !!link && /#\/here$/.test(link.href), JSON.stringify(link));
  ok("...reading as a count of people", !!link && /^\d+ here$/.test(link.text),
     JSON.stringify(link && link.text));
  /* NOT UNDERLINED AT REST. At rest it is a quiet fact beside the composer; the
     underline is what announces it as clickable under the pointer. */
  ok("...not underlined at rest", !!link && link.rest === "none", JSON.stringify(link && link.rest));

  const hovered = await page.evaluate(async () => {
    const a = document.querySelector(".chathere a");
    // :hover cannot be forced from script, so the RULE is read instead — the
    // thing that would be lost if somebody deleted the affordance.
    let found = false;
    for (const sheet of document.styleSheets) {
      let rules; try { rules = sheet.cssRules; } catch (e) { continue; }
      for (const r of rules) {
        if (r.selectorText && /chatherelink:hover/.test(r.selectorText)
            && /underline/.test(r.style.textDecorationLine || r.style.textDecoration || "")) {
          found = true;
        }
      }
    }
    return {found, cls: a ? a.className : null};
  });
  ok("...and underlined on hover", hovered.found === true, JSON.stringify(hovered));

  // ---- the page it reaches -------------------------------------------------
  /* A CHAT SERVICE HAS TO BE NAMED, or the route correctly reports it has
     nowhere to read from and never fetches at all — chatBase() is "" on file://.
     The hash is then changed in place rather than navigated to, because a goto
     reloads the document and CFG goes back to its defaults. */
  await page.evaluate(() => { CFG.chat = "http://chat.invalid"; });
  await page.evaluate(() => { location.hash = "#/here"; });
  await new Promise(z => setTimeout(z, 1200));

  const seen = await page.evaluate(() => ({
    text: document.querySelector("main").innerText,
    rows: [...document.querySelectorAll("main table.herelist tbody tr")]
      .map(tr => [...tr.querySelectorAll("td")].map(td => td.textContent.trim())),
    asked: window.__asked.slice(),
    bars: document.querySelectorAll("main .herebar").length,
  }));

  /* THE ENDPOINT IS PART OF THE REQUIREMENT. It must ask the presence endpoint
     and must NOT ask the diagnostics one, which would name the answerer. */
  ok("the page asks /api/chat/here",
     seen.asked.some(u => /\/api\/chat\/here/.test(u)), JSON.stringify(seen.asked));
  ok("...and never asks /api/chat/diag",
     !seen.asked.some(u => /\/api\/chat\/diag/.test(u)), JSON.stringify(seen.asked));

  ok("every named country is listed with its count",
     seen.rows.length === 4 && seen.rows.some(r => r.includes("US") && r.includes("7"))
     && seen.rows.some(r => r.includes("DE")) && seen.rows.some(r => r.includes("NO")),
     JSON.stringify(seen.rows));
  ok("...and the unplaceable are one row with no location on it",
     seen.rows.some(r => r.join(" ").includes("elsewhere") && r.includes("4")),
     JSON.stringify(seen.rows));
  ok("...drawn as bars, so the rows compare to each other", seen.bars >= 3, String(seen.bars));

  /* NO TOTAL, and this is not an omission. The chat line counts the reader
     looking at it and the tally counts placed connections, so a total here
     would visibly disagree with the number they clicked on. 16 is the sum of
     these rows and 14 is what the panel said; neither should appear. */
  ok("the page prints no grand total",
     !/\b16 (people|here|connections)\b/.test(seen.text) && !/\b14 here\b/.test(seen.text),
     JSON.stringify(seen.text.replace(/\s+/g, " ").slice(0, 200)));

  /* AND NOTHING PERSONAL. None of this is in the payload; a page that showed a
     heading for any of it would be a page inviting the service to publish it. */
  /* NAMES, not the words. "room" as a word is fine and the rule permits a COUNT
     of rooms — what must never appear is WHICH room, which network, or anything
     joined to a person. The demo's own court slugs are the concrete test: if one
     of those ever shows up here, the page has started reporting where people are
     rather than only which countries they are in. */
  for (const forbidden of ["moniker", "anon", "hello", "ip hash", "hash",
                           "address", "orem", "covid", "ledger", "annex"]) {
    ok(`the page does not show "${forbidden.trim()}"`,
       !seen.text.toLowerCase().includes(forbidden),
       JSON.stringify(seen.text.replace(/\s+/g, " ").slice(0, 160)));
  }

  /* ---- THE MAP -------------------------------------------------------------
     Asked for in these words: "i want to see where on the globe users are
     from". The table answers it in numbers; the map answers it as a picture,
     which is the thing that was actually requested.
     WHY THESE CHECKS ARE GEOMETRIC. A world map that renders is not a world map
     that is RIGHT, and every wrong version of this passed a check for "an svg
     exists" — the first render had two solid bands straight across it. So what
     is measured here is where the ink lands: whether a country's dot falls on
     the drawn land, and whether any coastline ring spans a width no real
     landmass can. */
  const map = await page.evaluate(() => {
    const svg = document.querySelector("main svg.heremap");
    if (!svg) return {svg: false};
    const land = svg.querySelector("path.heremapland");
    const dots = [...svg.querySelectorAll("circle.heremapdot")];
    const d = land ? land.getAttribute("d") : "";
    // Each subpath's horizontal extent, in viewBox units.
    const spans = d.split("M").filter(s => s.trim()).map(s => {
      const n = (s.match(/-?\d+(?:\.\d+)?/g) || []).map(Number);
      const xs = n.filter((_, i) => i % 2 === 0);
      return Math.max(...xs) - Math.min(...xs);
    });
    // isPointInFill is the real question: is this dot on the land or in the sea?
    const onLand = (c) => {
      const p = svg.createSVGPoint();
      p.x = +c.getAttribute("cx");
      p.y = +c.getAttribute("cy");
      return land.isPointInFill(p);
    };
    return {
      svg: true,
      rings: spans.length,
      widest: Math.max(...spans),
      dots: dots.length,
      halos: svg.querySelectorAll("circle.heremaphalo").length,
      titles: [...svg.querySelectorAll("title")].map(t => t.textContent),
      byR: dots.map(c => +c.getAttribute("r")),
      onLand: dots.map(onLand),
      // The land must be drawn from theme variables, not baked colours — so the
      // rendered fill is compared against the variable itself, not merely
      // checked for being non-transparent (which a hardcoded ocean would pass).
      landFill: getComputedStyle(land).fill,
      themeVar: (() => {
        const v = getComputedStyle(document.documentElement)
          .getPropertyValue("--surface-2").trim();
        const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(v);
        return m ? `rgb(${parseInt(m[1], 16)}, ${parseInt(m[2], 16)}, ${parseInt(m[3], 16)})` : v;
      })(),
      hidden: svg.getAttribute("aria-hidden"),
      vb: svg.getAttribute("viewBox"),
    };
  });

  ok("the page draws a world map", map.svg === true, JSON.stringify(map));
  ok(`...with a coastline of many separate landmasses (${map.rings})`,
     map.rings > 60, JSON.stringify(map.rings));
  /* THE ANTIMERIDIAN, WHICH IS THE BUG THIS FILE EXISTS TO CATCH. In this
     projection a polygon that crosses the dateline is drawn as a rectangle the
     full width of the map. MEASURED on the broken version: rings spanning all
     720 units, two visible bands, every other check still green. The widest
     legitimate landmass is Eurasia at 395 units — 55% — so anything past 75%
     is the wrap coming back. */
  ok(`...and no landmass spans the whole map (widest ${Math.round(map.widest)} of 720)`,
     map.widest < 720 * 0.75, JSON.stringify(map.widest));

  ok(`one dot per placeable country (${map.dots} for ${HERE.by_country.length})`,
     map.dots === HERE.by_country.length, JSON.stringify(map));
  ok("...each with a wash behind it, so the smallest is still findable",
     map.halos === map.dots, JSON.stringify({dots: map.dots, halos: map.halos}));
  /* AND EVERY ONE OF THEM IS ON LAND. US, DE and NO are all mainland countries,
     so a dot in the sea means the projection or the centroid table is wrong —
     the failure that a "does an svg exist" check cannot see. */
  ok("...and every dot lands on the drawn land rather than the sea",
     map.onLand.length > 0 && map.onLand.every(Boolean), JSON.stringify(map.onLand));
  /* THE AREA CARRIES THE COUNT, not the width — twice the people should look
     twice as big, and a doubled radius looks four times as big. Checked as an
     ORDER rather than a formula, so the constants can be tuned without a test
     rewrite, but a map that drew every country the same size would fail. */
  ok(`...and a busier country gets a bigger dot (${JSON.stringify(map.byR)})`,
     map.byR.length === 3 && map.byR[0] > map.byR[1] && map.byR[1] > map.byR[2],
     JSON.stringify(map.byR));
  ok("...labelled on hover with the country and its count, and nothing else",
     map.titles.length === map.dots
     && map.titles.every(t => /^[A-Z]{2} · \d+$/.test(t)), JSON.stringify(map.titles));
  /* THE COLOURS COME FROM THE THEME. This page renders on four palettes and the
     panel has no access to their tokens; a literal ocean would be wrong on at
     least one. Asserted as "not transparent and not black", which is what a
     missing variable resolves to. */
  ok(`...drawn in the theme's own colour, not a baked one (${map.landFill})`,
     !!map.landFill && map.landFill === map.themeVar,
     JSON.stringify({fill: map.landFill, ["--surface-2"]: map.themeVar}));
  /* HIDDEN FROM A SCREEN READER, DELIBERATELY, because the table underneath is
     the same numbers in a form that can actually be read out. */
  ok("...and left to the table for anybody using a screen reader",
     map.hidden === "true", JSON.stringify(map.hidden));

  /* AN ISLAND TOO SMALL TO DRAW STILL GETS ITS DOT, and the dot is on water.
     PINNED ON PURPOSE so that nobody "fixes" it by moving Singapore inland: at
     1:110m Singapore, Hong Kong, Malta and the whole Caribbean have no polygon
     at all, and lowering the threshold does not bring them back (measured: +220
     characters, 8 more rings, none of them these). The dot is in the right
     place; it is the coastline that cannot resolve it. */
  const island = await page.evaluate(() => {
    const html = hereMapHtml({by_country: [{cc: "SG", n: 3}], elsewhere: 0, geo_known: true});
    const host = document.createElement("div");
    host.innerHTML = html;
    document.body.appendChild(host);
    const svg = host.querySelector("svg"), land = svg.querySelector("path.heremapland");
    const c = svg.querySelector("circle.heremapdot");
    const p = svg.createSVGPoint(); p.x = +c.getAttribute("cx"); p.y = +c.getAttribute("cy");
    const r = {drawn: !!c, onLand: land.isPointInFill(p),
               cx: +c.getAttribute("cx"), cy: +c.getAttribute("cy")};
    host.remove();
    return r;
  });
  ok("an island with no polygon still gets a dot", island.drawn === true, JSON.stringify(island));
  ok("...sitting on open water, because the coastline cannot draw it",
     island.onLand === false, JSON.stringify(island));
  /* ...IN THE RIGHT PLACE ANYWAY. Singapore is 1N 104E. Worked out from the
     projection rather than read off the render: x = (104+180)/360*720 = 568,
     y = (84-1)/140*280 = 166. If the dot were being dropped at the origin, or
     mirrored, or scaled by the wrong axis, this is what would catch it. */
  ok(`...and in the right place regardless (${island.cx}, ${island.cy})`,
     Math.abs(island.cx - 568) < 6 && Math.abs(island.cy - 166) < 6, JSON.stringify(island));

  /* A CODE THE TABLE HAS NEVER HEARD OF GETS NO DOT AND KEEPS ITS ROW. The geo
     databases emit a few things that are not ISO countries; none of them may
     become a dot at 0,0 in the Atlantic. */
  const odd = await page.evaluate(() => {
    const host = document.createElement("div");
    host.innerHTML = hereMapHtml({
      by_country: [{cc: "ZZ", n: 4}, {cc: "US", n: 2}, {cc: "", n: 9}, {cc: "DE", n: 0}],
      elsewhere: 0, geo_known: true,
    });
    document.body.appendChild(host);
    const n = host.querySelectorAll("circle.heremapdot").length;
    const t = [...host.querySelectorAll("title")].map(x => x.textContent);
    host.remove();
    return {dots: n, titles: t};
  });
  ok("an unplaceable or empty country code draws no dot",
     odd.dots === 1 && odd.titles.join() === "US · 2", JSON.stringify(odd));

  /* AND NO MAP AT ALL WHEN NOBODY CAN BE PLACED. A server with no country file
     places everybody under "elsewhere"; an empty world with a graticule on it
     would imply the map had looked and found nothing, which is not what
     happened. */
  await page.evaluate(() => { window.__nogeo = true; });
  const nogeo = await page.evaluate(async () => {
    const real = window.fetch;
    window.fetch = async (url, opt) => {
      if (/\/api\/chat\/here/.test(String(url))) {
        return new Response(JSON.stringify({by_country: [], elsewhere: 5,
          networks: 2, rooms: 1, geo_known: false}),
          {status: 200, headers: {"Content-Type": "application/json"}});
      }
      return real(url, opt);
    };
    location.hash = "#/";
    await new Promise(r => setTimeout(r, 300));
    location.hash = "#/here";
    await new Promise(r => setTimeout(r, 1400));
    return {maps: document.querySelectorAll("main svg.heremap").length,
            text: document.querySelector("main").innerText};
  });
  ok("a server that cannot place anybody draws no map",
     nogeo.maps === 0, JSON.stringify(nogeo.maps));
  ok("...and says so in words instead",
     /no country file/i.test(nogeo.text),
     JSON.stringify(nogeo.text.replace(/\s+/g, " ").slice(0, 160)));

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
