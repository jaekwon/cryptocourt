// HOW MANY ARE IN THE ROOM, ABOVE THE BOX YOU TYPE INTO.
//
// Asked for in those terms — "the chat should also above the chat box show how
// many people are active" — and the placement is the requirement, not a detail:
// the moment that number matters is when you are deciding whether it is worth
// saying anything, which is when you are looking at the composer.
//
// WHY A BROWSER. "Above" is a fact about layout. A source test can find the
// element in the markup and say nothing about where it ends up, and this panel
// is a flex column whose order comes from the stylesheet as much as from the
// HTML — so the assertion is geometric: the line's bottom edge must be at or
// above the form's top edge, on screen.
//
// AND WHAT IT MUST NOT SAY. The count includes the site's own answerer as one
// more anonymous participant, decided server-side, and the panel is given a
// total with no way to decompose it. So this also checks that the line names no
// helper, no bot and no machine of any kind — if it did, the count would be the
// thing that gave the answerer away.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  await page.goto(PAGE + '#/c/orem', {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1200));

  const seen = await page.evaluate(() => {
    const here = document.querySelector(".chathere");
    const form = document.querySelector(".chatform");
    const input = document.querySelector(".chatinput");
    if (!here || !form) return {missing: {here: !!here, form: !!form}};
    const h = here.getBoundingClientRect(), f = form.getBoundingClientRect();
    return {
      text: here.textContent.trim(),
      hidden: here.hidden,
      shown: h.width > 0 && h.height > 0,
      // "above" as the reader experiences it
      aboveForm: h.bottom <= f.top + 1,
      gap: +(f.top - h.bottom).toFixed(1),
      // ...and it is the composer that is below it, not merely some form
      hasInput: !!input,
      // the panel is a flex column; document order should agree with the pixels
      beforeFormInDom: !!(here.compareDocumentPosition(form) &
                          Node.DOCUMENT_POSITION_FOLLOWING),
    };
  });

  ok("the panel has a count line and a composer",
     seen && !seen.missing, JSON.stringify(seen));
  if (!seen || seen.missing) { console.log("\n1 FAILURES"); await browser.close(); process.exit(1); }

  ok("the count is shown", seen.hidden === false && seen.shown === true,
     JSON.stringify(seen));
  // The sample supplies 3 — there is no server here to ask.
  ok("...and reads as a count of people in the room", /^\d+ here$/.test(seen.text),
     JSON.stringify(seen.text));

  /* THE PLACEMENT, WHICH IS THE REQUIREMENT. Measured in pixels, because that is
     what "above the chat box" means to a reader; the DOM-order check beside it
     is there so a stylesheet that reorders the column fails one of the two
     rather than passing both. */
  ok("it sits above the box you type into", seen.aboveForm === true,
     JSON.stringify(seen));
  ok("...and above it in document order too", seen.beforeFormInDom === true,
     JSON.stringify(seen));
  ok("...and the thing below it really is the composer", seen.hasInput === true);

  /* AND IT GIVES NOTHING AWAY. The total counts the site's own answerer as one
     more anonymous participant; a line that labelled it would undo that. */
  for (const tell of ["bot", "helper", "assistant", "ai", "machine", "system"]) {
    ok(`the line does not say "${tell}"`,
       !seen.text.toLowerCase().includes(tell), JSON.stringify(seen.text));
  }

  /* WHAT IS NOT ASSERTED HERE, and why, because a fake check is worse than a
     missing one. showHere hides the line for a missing or zero count — so that
     a lone reader is never told "0 here" while plainly being in the room — and
     that branch cannot be reached from this harness: showHere is a closure
     inside mountChat, and the sample always supplies a count. The first version
     of this file "tested" it by setting hidden and textContent itself and then
     asserting what it had just set, which is a tautology dressed as coverage.
     The guard is one line and its shape is pinned by the source suite instead. */

  /* AND THE LIVE PATH PAINTS THE SERVER'S NUMBER, which is the wire between the
     two halves that were already covered — the service sends `here` (pinned in
     diag_test) and the sample paints a count (pinned above) — and which was
     itself covered by NEITHER. MEASURED: deleting showHere(d.here) from the poll
     failed zero tests, source and browser alike. The demo path calls showHere
     with its own constant, so it cannot notice.
     THE SERVICE IS STUBBED, for the same reason diag_page stubs it: a real
     kourtchat here would be a database and a port, and what is being tested is
     that a number arriving on the wire reaches the element. */
  const live = await (async () => {
    const p2 = await browser.newPage();
    const seen = [];
    p2.on('pageerror', e => seen.push(String(e.message || e)));
    await p2.evaluateOnNewDocument(() => {
      const real = window.fetch;
      window.fetch = async (url, opt) => {
        const u = String(url);
        if (/\/api\/chat\//.test(u) && !/health|diag|botkey/.test(u)) {
          // The shape the panel's own allowlist reads, with a count on it.
          return new Response(JSON.stringify({
            messages: [{id: 41, moniker: "alice", body: "a live message", created_at: 1757000000}],
            next: 42, you: {state: "ok"}, now: 1757000005, here: 7,
          }), {status: 200, headers: {"Content-Type": "application/json"}});
        }
        if (/\/api\/chat\/health/.test(u)) {
          return new Response(JSON.stringify({ok: true, enforcing: true}),
            {status: 200, headers: {"Content-Type": "application/json"}});
        }
        return real(url, opt);
      };
    });
    await p2.goto(PAGE + '#/', {waitUntil: 'networkidle0'});
    /* THE PANEL IS MOUNTED DIRECTLY IN LIVE MODE rather than the whole overlay
       being switched over. chatEndpoint returns "" when cfg.mode is "demo", so
       live mode is the requirement here — but flipping CFG.mode would also send
       the court page off to read a chain that is not there, and the page errors
       from that would drown the thing being measured. mountChat is the seam. */
    const got = await p2.evaluate(async () => {
      const host = document.createElement("div");
      host.id = "livechat";
      document.body.appendChild(host);
      window.__stop = mountChat(host, {
        cfg: {mode: "live", chat: "http://chat.invalid"},
        chain: "dev", court: "orem", heading: false,
      });
      await new Promise(r => setTimeout(r, 1200));
      const el = host.querySelector(".chathere");
      return {text: el ? el.textContent.trim() : null,
              hidden: el ? el.hidden : null,
              rows: host.querySelectorAll(".chatlog > *").length,
              body: (host.querySelector(".chatlog") || {}).textContent || ""};
    });
    await p2.evaluate(() => { if (window.__stop) window.__stop(); });
    await p2.close();
    return {got, errs: seen};
  })();

  ok("the live panel really did poll and render what the service sent",
     live.got.rows > 0 && /a live message/.test(live.got.body), JSON.stringify(live.got));
  ok("...and the count it shows is the one the service sent",
     live.got.text === "7 here" && live.got.hidden === false,
     JSON.stringify(live.got));
  ok("no page errors on the live path", live.errs.length === 0,
     live.errs.slice(0, 2).join(" | "));

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
