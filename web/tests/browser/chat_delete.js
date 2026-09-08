// /delete SCRUBS THE MESSAGE FROM EVERY PANEL, because the server stopped
// sending it.
//
// THERE IS NO DELETE MESSAGE AND NO CLIENT BOOKKEEPING, which is the design
// worth protecting. The panel re-reads the whole window on every poll and paints
// it wholesale — the same mechanism that makes a moderator's hide vanish from a
// screen already showing it, which pulse.go describes — so a withdrawn message
// simply is not in the next payload and disappears. Nothing has to interpret a
// command, and nothing has to remember what was removed.
//
// THAT IS ALSO WHAT COULD QUIETLY BREAK. If the panel ever appended to the log
// instead of replacing it — an optimisation somebody might reach for, since
// repainting fifty rows to add one looks wasteful — deletion would stop working
// while every other test kept passing. This is the test that would fail.
//
// TWO TABS, because "every browser" is the requirement and one panel cannot
// show that a second one also forgets. Two panels in ONE tab does not work —
// mountChat is single-instance per document, measured — and is not the scenario
// anyway.
const {PAGE, demoPage} = require('./harness');

const BEFORE = [
  {id: 41, moniker: "alice", body: "something regrettable", created_at: 1757000000},
  {id: 42, moniker: "bob", body: "a reply that stays", created_at: 1757000010},
];
// The same window a moment later, with 41 withdrawn — which is all the server
// does: it stops including it.
const AFTER = [BEFORE[1]];

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  /* TWO TABS, NOT TWO PANELS IN ONE TAB. mountChat is single-instance per
     document — MEASURED: mounting a second panel left the first one blank,
     because the second mount takes over the poller. That is fine and not what
     "every browser" means anyway; readers are in separate tabs. */
  const openPanel = async () => {
    const p = await browser.newPage();
    p.on('pageerror', e => errs.push(String(e.message || e)));
    await p.evaluateOnNewDocument((before, after) => {
      window.__withdrawn = false;
      const real = window.fetch;
      window.fetch = async (url, opt) => {
        const u = String(url);
        if (/\/api\/chat\/health/.test(u)) {
          return new Response(JSON.stringify({ok: true, enforcing: true}),
            {status: 200, headers: {"Content-Type": "application/json"}});
        }
        if (/\/api\/chat\//.test(u)) {
          const msgs = window.__withdrawn ? after : before;
          return new Response(JSON.stringify({
            messages: msgs, next: 43, you: {state: "ok"}, now: 1757000020, here: 2,
          }), {status: 200, headers: {"Content-Type": "application/json"}});
        }
        return real(url, opt);
      };
    }, BEFORE, AFTER);
    await p.goto(PAGE + '#/', {waitUntil: 'networkidle0'});
    await p.evaluate(() => {
      const host = document.createElement("div");
      host.id = "panel";
      document.body.appendChild(host);
      window.__stop = mountChat(host, {
        cfg: {mode: "live", chat: "http://chat.invalid"},
        chain: "dev", court: "orem", heading: false,
      });
    });
    return p;
  };
  const log = p => p.evaluate(() =>
    (document.querySelector("#panel .chatlog") || {}).textContent || "");

  const tabA = await openPanel();
  const tabB = await openPanel();
  await new Promise(z => setTimeout(z, 1400));

  let a = await log(tabA), b = await log(tabB);
  ok("both tabs show the message to begin with",
     /something regrettable/.test(a) && /something regrettable/.test(b),
     JSON.stringify({a: a.slice(0, 80), b: b.slice(0, 80)}));
  ok("...and the one that stays", /a reply that stays/.test(a));

  /* THE SERVER STOPS SENDING IT. No delete event, no instruction to the client:
     the next window simply does not contain row 41. */
  await tabA.evaluate(() => { window.__withdrawn = true; });
  await tabB.evaluate(() => { window.__withdrawn = true; });
  // Long enough for each panel's own poll interval to come round.
  await new Promise(z => setTimeout(z, 8000));

  a = await log(tabA); b = await log(tabB);
  ok("the withdrawn message is gone from the first tab",
     !/something regrettable/.test(a), JSON.stringify(a.slice(0, 140)));
  ok("...and from the second, which was never told anything either",
     !/something regrettable/.test(b), JSON.stringify(b.slice(0, 140)));
  /* AND ONLY THAT ONE. A panel that cleared its log on any change would pass the
     two checks above while destroying the conversation. */
  ok("...while the rest of the transcript is untouched",
     /a reply that stays/.test(a) && /a reply that stays/.test(b),
     JSON.stringify({a: a.slice(0, 80), b: b.slice(0, 80)}));

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  for (const p of [tabA, tabB]) {
    await p.evaluate(() => { if (window.__stop) window.__stop(); });
    await p.close();
  }
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
