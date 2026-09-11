// THE DIAGNOSTICS PAGE, AND CHIEFLY WHAT IT MUST NOT SHOW.
//
// The service is what decides the payload — internal/chat/diag.go carries the
// allow/deny rule and diag_test.go checks the JSON against a list of keys. This
// file checks the other half: that the PAGE renders what it is given, and that
// it invents nothing and echoes nothing it should not.
//
// WHY A BROWSER. The route builds its table from a fetch, binds a submit
// handler, and re-reads on a timer. None of that exists until a document does.
//
// THE SERVICE IS STUBBED rather than run. A real kourtchat here would mean a
// database, a port and a second process to tear down, and none of it would make
// the assertions stronger: what is being tested is the rendering of a payload,
// so the payload is supplied directly. The shape it is given is the shape
// diag_test.go pins on the other side of the wire.
const {PAGE, demoPage} = require('./harness');

const PAYLOAD = {
  ok: true,
  holding: 4,
  holding_peak: 11,
  /* THE PRESENCE TALLIES. Four connections: two in Germany, one in the United
     States, one from an address the country file does not cover. The service has
     already applied its floor, so DE is a row and the other two arrived summed
     into here_elsewhere — the page cannot take that apart and this payload is
     the proof it is never asked to. */
  here_networks: 3,
  here_rooms: 2,
  here_by_country: [{cc: "DE", n: 2}],
  here_elsewhere: 2,
  geo_known: true,
  courts_active: 2,
  messages_last_hour: 37,
  bot_key_set: false,
  bot: {
    enabled: true, model: "claude-haiku-4-5-20251001",
    replies: 9, passes: 4, last_at: 1757000000,
    in_tokens: 12345, out_tokens: 678, cost_micros: 15735,
    failures: 6, last_fail_at: 1757000900, fail_kind: "refused",
    undelivered: 2,
    // A ceiling with room left in it: $0.50 of $2.00.
    cap_micros: 2000000, spent_today: 500000,
  },
};

// A key that must never appear on the page, in any form. It is not in the
// payload — the service does not publish it — so this is a check that the page
// does not somehow acquire it from the form field it renders.
const SECRET = "sk-ant-must-never-be-rendered-0001";

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // Installed before any script runs, so the route's own fetch is the stubbed
  // one. Records what was asked for, which is how the POST is checked.
  await page.evaluateOnNewDocument((payload, secret) => {
    window.__asked = [];
    window.__posted = [];
    const real = window.fetch;
    window.fetch = async (url, opt) => {
      const u = String(url);
      window.__asked.push(u);
      if (u.includes("/api/chat/diag")) {
        return new Response(JSON.stringify(window.__payload || payload),
          {status: 200, headers: {"Content-Type": "application/json"}});
      }
      if (u.includes("/api/chat/botkey")) {
        window.__posted.push(opt && opt.body);
        return new Response(JSON.stringify({ok: true}),
          {status: 200, headers: {"Content-Type": "application/json"}});
      }
      return real(url, opt);
    };
    window.__secret = secret;
  }, PAYLOAD, SECRET);

  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  /* A CHAT SERVICE HAS TO BE NAMED, or the route correctly reports that it has
     nowhere to read from. defaultChatBase() is "" on file:// — the offline demo
     has no service — so the harness supplies one, which is also what makes the
     stub above the thing being answered. Set BEFORE the route runs, because the
     route reads it once at render. */
  await page.evaluate(() => { CFG.chat = "http://chat.invalid"; });
  await page.goto(PAGE + '#/diag', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 900));

  const seen = await page.evaluate(() => ({
    text: document.querySelector("main") ? document.querySelector("main").innerText : "",
    html: document.querySelector("main") ? document.querySelector("main").innerHTML : "",
    hasForm: !!document.getElementById("diag-key"),
    asked: window.__asked.slice(),
  }));

  ok("the page asked the service for the payload",
     seen.asked.some(u => u.includes("/api/chat/diag")), JSON.stringify(seen.asked));

  /* EVERY NUMBER IT WAS GIVEN, READ OFF ITS OWN ROW. The first version of this
     searched the whole page for "4" and "2", which a page of prose satisfies
     without rendering anything — it passed against a page showing none of them.
     A row is looked up by its label and its value cell is compared. */
  const cells = await page.evaluate(() => {
    const out = {};
    for (const tr of document.querySelectorAll("main table.tbl tr")) {
      const td = tr.querySelectorAll("td");
      if (td.length >= 2) out[td[0].textContent.trim()] = td[1].textContent.trim();
    }
    return out;
  });
  const wants = {
    "Holding now": "4", "Most at once": "11", "Rooms active": "2",
    "Networks": "3", "Rooms being read": "2",
    "Messages, last hour": "37", "Answered": "9", "Passed on": "4",
    "Calls failed": "6 · refused", "Not delivered": "2",
  };
  for (const [label, want] of Object.entries(wants)) {
    ok(`"${label}" reads ${want}`, cells[label] === want,
       JSON.stringify({got: cells[label], cells}));
  }
  // 15735 micro-dollars is 1.57 cents. Two decimals renders that as "$0.02",
  // which throws away most of what the number said — a token bill spends
  // fractions of a cent at a time. MEASURED: this is what the page did first.
  ok("a fraction of a cent keeps enough decimals to be a spend",
     cells["Spent"] === "$0.0157", JSON.stringify(cells["Spent"]));

  /* TODAY AGAINST THE CEILING, which is the row that explains a silence. A
     capped helper says nothing, and silence here already had four causes a
     reader cannot tell apart — the gap, the local filter, a model pass, a room
     that refused the post. The ceiling was a fifth whose only record was the
     journal. The row above this one is the LIFETIME figure and says nothing
     about whether the helper can answer right now. */
  ok(`the day's spend is shown against the ceiling (${cells["Today"]})`,
     cells["Today"] === "$0.5000 of $2.00", JSON.stringify(cells["Today"]));
  /* ANSWERED AND PASSED ON ARE DIFFERENT ROWS, which is the defect this pair
     exists for: they were one number, and the page reported "3 replies" for an
     answerer that had never posted. A page that showed only one of them, or the
     same value in both, would be back where it started. */
  ok("answering and passing are reported separately",
     cells["Answered"] === "9" && cells["Passed on"] === "4"
     && cells["Answered"] !== cells["Passed on"], JSON.stringify(cells));
  ok("...and the tokens are reported as counted, both directions",
     /12,345 in/.test(cells["Tokens"] || "") && /678 out/.test(cells["Tokens"] || ""),
     JSON.stringify(cells["Tokens"]));

  /* AND AN UNDELIVERED REPLY IS ITS OWN ROW, not folded into the passes. It was
     reported as a pass once — the outcome that needs no attention — for a reply
     that had been written, billed, and refused by the room. */
  ok("a reply the room refused is reported apart from a pass",
     cells["Not delivered"] === "2" && cells["Passed on"] === "4"
     && cells["Not delivered"] !== cells["Passed on"], JSON.stringify(cells));

  /* A FAILING HELPER IS VISIBLE AS ONE. Without this row a refused key read
     exactly like an idle helper — every other number zero — on the page whose
     only job is telling those apart. */
  ok("a failing helper says so, and says which kind",
     /^6 · (refused|unreachable)$/.test(cells["Calls failed"] || ""),
     JSON.stringify(cells["Calls failed"]));
  ok("...and the row explains where to look",
     /key/i.test(Object.keys(cells).length ? seen.text : ""), "");

  /* ---- where the room is -------------------------------------------------
     THE COUNTRY IT WAS GIVEN, WITH ITS FLAG. The flag is chat.js's chatFlag
     rather than a second renderer here, so this also checks that the page can
     still reach it — the /diag route is not a chat route and nothing else on it
     calls into that file. */
  ok(`"Where" names the country it was given (${cells["Where"]})`,
     /DE\s*2/.test(cells["Where"] || ""), JSON.stringify(cells["Where"]));
  ok("...with the flag for it", /\u{1F1E9}\u{1F1EA}/u.test(cells["Where"] || ""),
     JSON.stringify(cells["Where"]));
  /* AND SAYS SO WHEN IT CANNOT SAY MORE. Two of the four connections are not in
     that row: one in a country under the service's floor and one from an address
     the file does not cover. They arrive already added together. */
  ok("...and the rest are one number called elsewhere",
     /elsewhere\s*2/.test(cells["Where"] || ""), JSON.stringify(cells["Where"]));
  /* THE GUARANTEE, FROM THE PAGE'S SIDE. The server in this scenario has one
     reader in the United States and the payload does not mention it, because a
     country with a single connection in it is a public statement about one
     person. The page cannot name what it was not told, and this is the assertion
     that would fail if the payload ever started telling it. */
  ok("...and names no country that was not in the payload",
     !/\bUS\b|\u{1F1FA}\u{1F1F8}/u.test(cells["Where"] || ""),
     JSON.stringify(cells["Where"]));
  /* THE ATTRIBUTION IS A LICENCE CONDITION of the country file, so it is checked
     like one rather than left to whoever edits the page next. */
  ok("the country data is credited to its source",
     /DB-IP/.test(seen.text) && /CC-BY/i.test(seen.text),
     seen.text.slice(-240));
  ok("...and the page says what the guess is worth",
     /VPN/i.test(seen.text), "");

  /* THE PAGE MUST NOT SHOW WHAT IT CANNOT KNOW, asked of the TABLE and not of
     the whole page. The prose above it promises that nothing here names a person
     or an address, and searching the whole page for "address" therefore fails on
     the sentence that makes the promise — which is what the first version of
     this did. The data is where a leak would be. */
  const dataText = Object.entries(cells).map(([k, v]) => k + " " + v).join(" ").toLowerCase();
  for (const forbidden of ["ip_hash", "ip hash", "address", "appeal", "backlog",
                           "unscannable", "enforcing", "moderator", "hash"]) {
    ok(`the data does not carry "${forbidden}"`, !dataText.includes(forbidden), dataText.slice(0, 160));
  }

  ok("the key form is offered while no key is set", seen.hasForm === true);

  // THE FIELD HIDES WHAT IS TYPED. A key pasted into a visible input is a key on
  // a screen in a room, and this page is one somebody may well be sharing.
  const inputType = await page.evaluate(() => {
    const el = document.getElementById("diag-key-v");
    return el ? el.getAttribute("type") : null;
  });
  ok("the key field is a password field, not a text field", inputType === "password");

  // SUBMITTING SENDS JSON, which is what the service's write guard requires: a
  // form-encoded POST is one of the shapes a cross-site page can make a browser
  // send, and csrfOK refuses exactly that.
  const posted = await page.evaluate(async (secret) => {
    document.getElementById("diag-key-v").value = secret;
    document.getElementById("diag-key").dispatchEvent(
      new Event("submit", {bubbles: true, cancelable: true}));
    await new Promise(z => setTimeout(z, 400));
    return {bodies: window.__posted.slice(),
            said: (document.getElementById("diag-key-say") || {}).textContent || ""};
  }, SECRET);
  ok("the form posts the key as JSON", posted.bodies.length === 1
     && /^\{"key":/.test(String(posted.bodies[0])), JSON.stringify(posted.bodies));
  ok("...and says what happened", /set|restart/i.test(posted.said), posted.said);

  // AND THE KEY IS NOT LEFT ON THE PAGE. The value stays in the field the reader
  // typed it into — that is the browser's own behaviour and not this page's
  // doing — but nothing may copy it into the document.
  const leaked = await page.evaluate((secret) => {
    const main = document.querySelector("main");
    return main ? main.innerHTML.includes(secret) : false;
  }, SECRET);
  ok("the key is never written into the page", leaked === false);

  // ONCE SET, THERE IS NOTHING TO OFFER. Re-read with the other payload.
  await page.evaluate(() => { window.__payload = Object.assign({}, window.__payload || {}); });
  await page.evaluate((p) => { window.__payload = p; },
    Object.assign({}, PAYLOAD, {bot_key_set: true}));
  await page.goto(PAGE + '#/', {waitUntil: 'networkidle0'});
  await page.evaluate(() => { CFG.chat = "http://chat.invalid"; });
  await page.goto(PAGE + '#/diag', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 900));
  const after = await page.evaluate(() => ({
    hasForm: !!document.getElementById("diag-key"),
    text: document.querySelector("main").innerText,
  }));
  ok("no form once a key is set", after.hasForm === false);
  ok("...and the page says it cannot be read back or replaced",
     /cannot be read back/i.test(after.text));

  /* WITH NO COUNTRY FILE, THE PAGE SAYS THAT rather than showing an empty row.
     Every connection lands in elsewhere on a deployment with no file, which is
     indistinguishable from a room full of readers in small countries — the same
     "healthy and idle looks like broken" trap the failure rows exist for. And the
     credit must go with the data: crediting a source on a deployment that has
     none would be a claim about where the numbers came from. */
  await page.evaluate((p) => { window.__payload = p; },
    Object.assign({}, PAYLOAD, {geo_known: false, here_by_country: [], here_elsewhere: 4}));
  await page.goto(PAGE + '#/', {waitUntil: 'networkidle0'});
  await page.evaluate(() => { CFG.chat = "http://chat.invalid"; });
  await page.goto(PAGE + '#/diag', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 900));
  const noGeo = await page.evaluate(() => {
    const out = {text: document.querySelector("main").innerText};
    for (const tr of document.querySelectorAll("main table.tbl tr")) {
      const td = tr.querySelectorAll("td");
      if (td.length >= 2 && td[0].textContent.trim() === "Where") out.where = td[1].textContent.trim();
    }
    return out;
  });
  ok("with no country file the page says so",
     /no country file/i.test(noGeo.where || ""), JSON.stringify(noGeo.where));
  ok("...and credits nobody for data it does not have",
     !/DB-IP/.test(noGeo.text), "the credit outlived the data");

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
