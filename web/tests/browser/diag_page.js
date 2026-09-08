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
  courts_active: 2,
  messages_last_hour: 37,
  bot_key_set: false,
  bot: {
    enabled: true, model: "claude-haiku-4-5-20251001",
    replies: 9, last_at: 1757000000,
    in_tokens: 12345, out_tokens: 678, cost_micros: 15735,
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
    "Messages, last hour": "37", "Replies": "9",
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
  ok("...and the tokens are reported as counted, both directions",
     /12,345 in/.test(cells["Tokens"] || "") && /678 out/.test(cells["Tokens"] || ""),
     JSON.stringify(cells["Tokens"]));

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

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
