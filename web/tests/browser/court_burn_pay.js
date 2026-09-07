// Creating a court attaches the burn the realm charges — or nothing, at zero.
//
// WHY THIS EXISTS, and it is the bug this whole check was written after finding.
// The overlay's payment plumbing was the single condition `func === "Buy"`, in
// three places. That was true right up until the realm started pricing court
// creation: with a burn set, StartCourt needs GNOT attached or it panics, so
// the directory's "Create a new court" button would have failed for every
// reader, with a realm error rather than anything actionable. Adding the burn
// without wiring this would have shipped a broken button.
//
// THE TWO DIRECTIONS ARE BOTH CHECKED, because each has its own failure:
//   - PRICED: both creation buttons must carry the amount, and the page must
//     SAY the price. A price a reader meets first in their wallet prompt is a
//     price sprung on them.
//   - AT ZERO: nothing attached and nothing claimed. Zero is the realm's
//     shipped default, so this is the state most chains are in, and a button
//     that sends coin nobody asked for would be worse than the original bug.
//
// ASSERTIONS READ RENDERED NODES, NEVER document.body.innerHTML. This page
// carries its entire source in an inline script, so a document-wide regex
// matches every template literal in the file whether it rendered or not — an
// earlier version of this check reported the zero case as showing the price,
// and the condition was right while the instrument was wrong. Everything below
// reads textContent off a specific element.
//
// EACH CASE CLEARS THE RPC CACHE. The overlay memoises answers in
// sessionStorage, which survives a reload, so the second case served the first
// one's price and asked the node nothing. See the note at the clearing loop.
//
// THE PRICE COMES FROM A STUBBED window.fetch. The overlay's read helpers are
// all `const` and puppeteer's request interception never sees a cross-origin
// fetch from a file:// page (measured: zero posts). Stubbing fetch leaves the
// envelope decode, parseTyped and the formatters as real code — see
// params_page.js, which established the same seam.
//
// ABLATED against a CONTROL run of the unmodified page, which fires nothing at
// 13 arms. Counts are what actually fired, and the FIRST ONE IS THE REASON THE
// SIGNING ARM EXISTS AT ALL:
//   - revert `takesCoin(func)` to `func === "Buy"` -> 1: the signed-amount arm.
//     An earlier version of this file fired ZERO on this mutation, because
//     every arm then read the rendered data-send attribute — which btn() writes
//     either way. The button would have attached no coin and the check would
//     have passed. Attribute presence and signed amount are different facts.
//   - drop the CLI `--send` branch -> 1: the copyable-command arm. Separate
//     from the above on purpose: the two paths a reader can take (wallet, and
//     paste-the-command) are wired independently and each can break alone.
//   - drop the `creationBurnNow > 0` guard on the dialog line -> 1: the
//     zero-case dialog arm.
//   - hand the buttons a hardcoded amount instead of the read -> 1: the
//     zero-case attachment arm.
// Mutations run against a COPY outside the repo: a second session edits this
// file, and an in-place mutation has been written back from a stale buffer once.
const {PAGE, demoPage} = require('./harness');

// Answer only CourtCreationBurn; everything else gets an empty string so the
// directory renders without the stub having to model the whole realm.
function stubBurn(burnMicro) {
  return async function (url, opts) {
    let expr = "";
    try { expr = atob(JSON.parse(opts.body).params.data); } catch (e) { expr = ""; }
    const val = /CourtCreationBurn/.test(expr) ? "(" + burnMicro + " int64)" : '("" string)';
    return {ok: true, status: 200, json: async () => ({
      jsonrpc: "2.0", id: "cc",
      result: {response: {ResponseBase: {Data: btoa(val)}}}})};
  };
}

(async () => {
  const {browser, page, errs} = await demoPage({width: 1400, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // A DISTINCT URL PER CASE, and it is not cosmetic. Navigating to the same
  // URL including the same hash is a SAME-DOCUMENT navigation: the page does
  // not reload, CFG keeps whatever the previous case set, and render() may skip
  // entirely on an unchanged route. Measured — the zero case read the priced
  // DOM and reported the burn attached when the stub was answering 0. The query
  // string is ignored by the app and makes each load a real one.
  const readDirectory = async burnMicro => {
    await page.goto(PAGE + '?case=' + burnMicro + '#/', {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 900));
    return page.evaluate(async (burn, stubSrc) => {
      /* THE RPC CACHE MUST GO FIRST, and finding this cost three wrong theories.
         The overlay memoises query answers in sessionStorage under `rpcc\0…`,
         and sessionStorage SURVIVES a reload in the same tab. So the second
         case served the first case's answer and made no request at all —
         measured: zero fetches, and the page still showing the priced amount.
         Any check that changes what the chain says between renders has to clear
         this, or it is reading the previous answer. */
      for (let i = sessionStorage.length - 1; i >= 0; i--) {
        const k = sessionStorage.key(i);
        if (k && k.indexOf("rpcc") === 0) sessionStorage.removeItem(k);
      }
      CFG.mode = "live";
      CFG.rpc = "http://stub.invalid/";
      const realFetch = window.fetch;
      // eslint-disable-next-line no-new-func
      window.fetch = new Function("return " + stubSrc)()(burn);
      try {
        await render();
        const dlg = document.getElementById('help-newcourt');
        const lead = document.querySelector('.lead-row');
        const creation = [...document.querySelectorAll('[data-send]')]
          .filter(e => /StartCourt/.test(e.outerHTML));
        return {
          // textContent of specific elements: see the note at the top.
          dialogText: dlg ? (dlg.textContent || "") : "<no dialog>",
          leadText: lead ? (lead.textContent || "") : "<no lead row>",
          sends: [...document.querySelectorAll('[data-send]')].map(e => e.dataset.send),
          creationSends: creation.map(e => e.dataset.send),
          createCli: (() => { const c = [...document.querySelectorAll('[data-cli]')]
            .find(e => /"StartCourt"/.test(e.dataset.cli || "")); return c ? c.dataset.cli : ""; })(),
        };
      } finally { window.fetch = realFetch; CFG.mode = "demo"; }
    }, burnMicro, stubBurn.toString());
  };

  // ---- PRICED at 2 GNOT.
  const priced = await readDirectory("2000000");
  ok("a priced realm attaches the burn to both creation buttons",
     priced.creationSends.length === 2 &&
     priced.creationSends.every(s => s === "2000000ugnot"),
     JSON.stringify(priced.creationSends));
  ok("...and the button itself states the price",
     /burns 2\.00 GNOT/.test(priced.leadText), priced.leadText.slice(0, 160));
  ok("...and says it is not refundable, beside the amount",
     /not refundable/.test(priced.leadText), priced.leadText.slice(0, 160));
  ok("...and the helper explains where the coin goes",
     /A burn, up front/.test(priced.dialogText) &&
     /keyless address/.test(priced.dialogText),
     priced.dialogText.slice(0, 200));

  // ---- OFF at zero, which is what the realm ships.
  const off = await readDirectory("0");
  ok("an unpriced realm attaches nothing to creation",
     off.creationSends.length === 0, JSON.stringify(off.creationSends));
  ok("...and claims no price on the button",
     !/burns .* GNOT/.test(off.leadText), off.leadText.slice(0, 160));
  ok("...and the helper says nothing about a burn",
     !/A burn, up front/.test(off.dialogText), off.dialogText.slice(0, 200));
  // The buttons must still BE there — "attaches nothing" would also be true of
  // a directory that stopped offering court creation at all.
  ok("...but the creation buttons are still offered",
     /Create a new court/.test(off.leadText), off.leadText.slice(0, 120));

  /* ---- WHAT WOULD ACTUALLY BE SIGNED, and this is the arm the check was
     missing. Everything above reads the rendered data-send attribute, which
     btn() writes regardless of the payment plumbing — so reverting takesCoin()
     to the old `func === "Buy"` fired NOTHING in ablation, while leaving the
     button attaching no coin at all. That is precisely the bug this file
     exists to catch, and the attribute cannot see it: the amount that gets
     signed is decided in the CLICK handler.
     So the wallet is stubbed, the button is pressed, the confirm dialog is
     driven, and the message handed to DoContract is inspected. */
  // ITS OWN PAGE LOAD, for the reason readDirectory has one: this block runs
  // after the zero case, and re-rendering an unchanged route does not
  // necessarily rebuild the DOM. Measured — without this the arm inspected the
  // ZERO case's buttons, found no data-send, and reported send:"" as though the
  // burn were not attached. The implementation was correct; the instrument was
  // reading the previous case.
  await page.goto(PAGE + '?case=sign#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 900));
  const signed = await page.evaluate(async (burn, stubSrc) => {
    for (let i = sessionStorage.length - 1; i >= 0; i--) {
      const k = sessionStorage.key(i);
      if (k && k.indexOf("rpcc") === 0) sessionStorage.removeItem(k);
    }
    CFG.mode = "live";
    CFG.rpc = "http://stub.invalid/";
    CFG.addr = "g1signstubaddress0000000000000000000000";
    const realFetch = window.fetch, realAdena = window.adena;
    // eslint-disable-next-line no-new-func
    window.fetch = new Function("return " + stubSrc)()(burn);
    let captured = null;
    /* The stub answers the WHOLE bridge the click path uses. GetNetwork was
       missing at first and the click died with "Adena: a.GetNetwork is not a
       function" — reported as a notice on the page rather than as an error, so
       the arm just saw no dialog and said nothing useful. A wallet stub that is
       missing a method fails as an absent feature. */
    window.adena = {
      // code:0 IS THE SUCCESS SIGNAL, not status:"success" — the overlay tests
      // `net.code !== 0` and reported "Adena would not answer: code undefined"
      // until this stub said so. Adena's own shape, and the reason a wallet
      // stub has to be read off the caller rather than imagined.
      AddEstablish:  async () => ({code: 0, status: "success"}),
      GetAccount:    async () => ({code: 0, status: "success",
                                   data: {address: CFG.addr, chainId: "kourt-1"}}),
      GetNetwork:    async () => ({code: 0, status: "success",
                                   data: {chainId: "kourt-1", rpcUrl: CFG.rpc}}),
      SwitchNetwork: async () => ({code: 0, status: "success"}),
      AddNetwork:    async () => ({code: 0, status: "success"}),
      DoContract: async msg => { captured = msg;
        return {code: 0, status: "success", data: {hash: "stubhash"}}; },
    };
    try {
      await render();
      const create = [...document.querySelectorAll('button,a')]
        .find(e => /Create a new court/.test(e.textContent || ""));
      if (!create) return {err: "no create button"};
      create.click();
      // The dialog is built synchronously inside the click handler's promise;
      // one turn is enough for it to exist.
      await new Promise(r => setTimeout(r, 250));
      const dlg = [...document.querySelectorAll('dialog')]
        .find(d => d.querySelector('[data-go]'));
      if (!dlg) return {err: "no sign dialog",
                        notices: [...document.querySelectorAll('.notice,.txnote')]
                          .map(n => (n.textContent || "").slice(0, 90))};
      const go = dlg.querySelector('[data-go]');
      if (!go) return {err: "no sign button", captured};
      go.click();
      await new Promise(r => setTimeout(r, 400));
      const val = captured && captured.messages && captured.messages[0] && captured.messages[0].value;
      return {send: val ? val.send : "<no message>", func: val ? val.func : ""};
    } finally {
      window.fetch = realFetch; window.adena = realAdena;
      CFG.mode = "demo"; delete CFG.addr;
    }
  }, "2000000", stubBurn.toString());

  ok("the copyable CLI carries the same --send", /--send 2000000ugnot/.test(priced.createCli || ""),
     (priced.createCli || "").slice(0, 200));
  ok("...and an unpriced realm's CLI has no --send at all",
     !/--send/.test(off.createCli || ""), (off.createCli || "").slice(0, 200));

  ok("pressing Create signs a StartCourt call", signed.func === "StartCourt",
     JSON.stringify(signed));
  ok("...with the burn actually attached to it", signed.send === "2000000ugnot",
     JSON.stringify(signed));

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
