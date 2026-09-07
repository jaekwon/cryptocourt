// The realm-parameters page: seven rows, live values, and an honest demo.
//
// WHY THIS EXISTS. The page answers "what is this realm configured to right
// now", which was previously eight separate queries and knowing which eight. A
// page like that fails in two silent ways, and both are checked here:
//   - IT SHOWS A NUMBER THAT IS NOT THE CHAIN'S. Every value is formatted from
//     the packed read, and a formatter pointed at the wrong key produces a
//     plausible figure in the right place. So the fixture feeds a line whose
//     values are all DISTINCT and each cell is matched against its own.
//   - IT DROPS A ROW. A listing that silently omits a setting reads as "these
//     are all of them", which is worse than not having the page.
//
// WHY IN A BROWSER. The page is assembled from a chain read, parsed, formatted
// through gnotAmt/ccFig, and written as a table. A source harness can check the
// parse but not that the value reaches the cell — and the failure this guards
// against is precisely a value landing in the wrong cell, or in none.
//
// THE READ IS STUBBED AT THE NETWORK, and it has to be stubbed at all for now:
// AdminParams() does not exist on the deployed chain until the next reseed, so a
// check that queried the live node would be red for reasons that have nothing to
// do with this page.
// WHERE the stub sits was arrived at by measurement, twice. The overlay's read
// helpers — abci, qeval, one — are every one of them `const`, so reassigning
// them throws "Assignment to constant variable". Puppeteer's request
// interception did not work either: it recorded ZERO posts, because a
// cross-origin fetch from a file:// page is blocked before interception can
// answer it, and the page fell to its own "could not read" notice.
// So window.fetch is replaced, which is an ordinary assignable global and the
// exact seam abciFetch calls. Everything above it is real: the JSON-RPC
// envelope decode, the base64, parseTyped, the pair parse, both formatters and
// the table build. Only the node is fake.
//
// A VALUE CONTAINING A COLON is fed deliberately. AdminParams' doc states that
// pairs split on the FIRST colon only, because a media host could contain one;
// a naive split(":") truncates it and the arm below is what notices.
//
// ABLATED against a CONTROL run of the unmodified page, which fires nothing at
// 17 arms — without that control "3 arms fired" is not evidence, since a copy
// broken for its own reasons reports the same. Counts below are what ACTUALLY
// fired, and two of them are not what this comment first predicted:
//   - point the burn cell at assocBond -> 1, not the 2 predicted. It reads
//     "7.00 GNOT": the burn arm alone. The bond arm still passes, because the
//     bond cell is right and only the burn cell moved — which is exactly the
//     discrimination distinct fixture values buy.
//   - drop one PARAM_ROWS entry -> 3, not 2: the row count (6), that row's
//     value ("no such row"), and the verb arm, since its verb goes with it.
//   - split pairs on every colon instead of the first -> 1: the colon arm,
//     reading a domain truncated to "kourt.example".
// A fourth mutation — making demo mode render the live table — is NOT recorded
// here because it was never run; the three above were enough to establish the
// arms are load bearing, and a count nobody measured has no business in a
// comment that the others make look authoritative.
// Mutations run against a COPY outside the repo: a second session edits this
// file, and an in-place mutation has been written back from a stale buffer once.
const {PAGE, demoPage} = require('./harness');

// Distinct values throughout, so no cell can pass by coincidence. The domain
// carries a colon to exercise the documented parse rule.
const PACKED = [
  'admin:g1paramsadminaddressfixture000000000000',
  'creationBurn:2500000',
  'assocBond:7000000',
  'purgeM:3',
  't1:11', 't2:22', 't3:33', 'entry:4', 'l2:44', 'l3:444',
  'flag:1111', 'dispute:2222', 'authorHigh:3333',
  'conviction:4444', 'unadjudicated:5555',
  'domain:kourt.example:8443',
  'mediaExact:exact-one.example,exact-two.example',
  'mediaSuffix:.suffix-one.example',
].join(';');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // ---- DEMO MODE tells the truth instead of inventing values.
  await page.goto(PAGE + '#/params', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 900));
  const demo = await page.evaluate(() => {
    const m = document.getElementById('main');
    return {text: (m.textContent || ''), rows: m.querySelectorAll('.paramtbl tbody tr').length};
  });
  ok("demo mode draws no value table", demo.rows === 0, `${demo.rows} rows`);
  ok("...and says why, pointing at the Source switch",
     /no chain|none to show/i.test(demo.text) && /Source/.test(demo.text),
     demo.text.slice(0, 140));
  ok("...and names the realm's own page as the alternative",
     /admin-params/.test(demo.text));

  // ---- LIVE MODE, with the node answered at window.fetch.
  const live = await page.evaluate(async (packed) => {
    CFG.mode = "live";
    CFG.rpc = "http://stub.invalid/";   // never actually contacted
    const realFetch = window.fetch;
    let asked = 0, sentExpr = "";
    window.fetch = async (url, opts) => {
      asked++;
      // Record what the page ASKED for, so the arms below cannot pass against a
      // stub that answered a question the page never posed.
      try { sentExpr = atob(JSON.parse(opts.body).params.data); } catch (e) { sentExpr = "<unparsable>"; }
      const payload = btoa('("' + packed + '" string)');
      return {ok: true, status: 200, json: async () => ({
        jsonrpc: "2.0", id: "cc",
        result: {response: {ResponseBase: {Data: payload}}}})};
    };
    try {
      await render();
      const cells = [...document.querySelectorAll('.paramtbl tbody tr')].map(tr => ({
        label: tr.children[0].textContent.trim(),
        value: tr.children[1].textContent.trim(),
        what: tr.children[2].textContent.trim(),
        verb: tr.children[3].textContent.trim(),
      }));
      return {cells, admin: (document.querySelector('.kv code') || {}).textContent || '',
              asked, sentExpr,
              // What the page SAID, for when there are no rows to inspect.
              text: (document.getElementById('main').textContent || '').slice(0, 300)};
    } finally { window.fetch = realFetch; CFG.mode = "demo"; }
  }, PACKED);

  // THE PAGE ASKED THE REALM FOR THE RIGHT THING. Without this, every arm below
  // would pass against a stub answering a question nobody asked — which is how
  // the previous version of this file reported ten failures while the page was
  // working: the read never happened at all.
  ok("the page makes exactly one chain read", live.asked === 1, `${live.asked} reads`);
  ok("...and it asks for AdminParams", /AdminParams\(\)/.test(live.sentExpr || ""),
     live.sentExpr);

  ok("live mode draws every parameter", live.cells.length === 7,
     `${live.cells.length} rows: ${live.cells.map(c => c.label).join(", ")} | page said: ${live.text}`);
  ok("...and names the admin it is describing",
     /g1paramsadminaddressfixture/.test(live.admin), live.admin);

  const cell = label => (live.cells.find(c => c.label === label) || {}).value || "<no such row>";

  // EACH VALUE AGAINST ITS OWN FIGURE. 2500000 µGNOT is 2.50 GNOT; 7000000 µCC
  // is 7.00 CC. Both formatters are the page's own, so a change to either shows
  // up here rather than silently reshaping the page.
  ok("the burn shows its own figure, in GNOT",
     /2\.50\s*GNOT/.test(cell("Court creation burn")), cell("Court creation burn"));
  ok("the bond shows its own figure, in CC",
     /7\.00\s*CC/.test(cell("Association bond")), cell("Association bond"));
  ok("the purge threshold is the DAO's m",
     cell("Purge threshold") === "3", cell("Purge threshold"));
  ok("the ladder shows all six of its numbers",
     /11\/22\/33 bps at 4\/44\/444 posts/.test(cell("Posting ladder")),
     cell("Posting ladder"));
  ok("the standing rates show all five, each labelled",
     /flag 1111/.test(cell("Standing rates")) && /dispute 2222/.test(cell("Standing rates")) &&
     /author 3333/.test(cell("Standing rates")) && /conviction 4444/.test(cell("Standing rates")) &&
     /unadjudicated 5555/.test(cell("Standing rates")),
     cell("Standing rates"));

  // THE DOCUMENTED PARSE RULE. The fixture's domain contains a colon; split on
  // every colon and this arrives truncated to "kourt.example".
  ok("a value containing a colon survives the parse",
     /kourt\.example:8443/.test(cell("Site domain")), cell("Site domain"));

  ok("the media hosts list exact hosts and suffixes apart",
     /exact-one\.example/.test(cell("Media hosts")) &&
     /exact-two\.example/.test(cell("Media hosts")) &&
     /suffixes/.test(cell("Media hosts")) &&
     /\.suffix-one\.example/.test(cell("Media hosts")),
     cell("Media hosts"));

  // Every row says how to change it — the question after "what is it".
  const verbs = live.cells.map(c => c.verb).join(" ");
  ok("every row names the verb that sets it",
     live.cells.length > 0 &&
     ["SetCourtCreationBurn", "SetAssociationBondDefault", "SetPurgeThreshold",
      "SetLadderDefault", "SetCreditRatesDefault", "SetSiteDomain", "SetMediaHosts"]
       .every(v => verbs.includes(v)), verbs);
  // And explains itself: an empty explanation column would pass every arm above.
  ok("every row explains what it does",
     live.cells.length > 0 && live.cells.every(c => c.what.length > 20),
     JSON.stringify(live.cells.map(c => c.what.length)));

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
