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

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
