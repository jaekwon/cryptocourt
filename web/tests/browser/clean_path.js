// A URL SOMEBODY TYPES BY HAND HAS TO LAND SOMEWHERE REAL.
//
// WHY THIS EXISTS, AND IT WAS REPORTED AS SOMETHING ELSE ENTIRELY. "Typing in
// the chat at kourt.xyz/covid doesn't work anymore." Every part of the chat was
// working: the service accepted a POST, the panel mounted, Enter sent, the text
// survived a poll cycle, and forty consecutive posts in the access log were 200.
//
// The URL was the bug. nginx serves index.html for any path it has no file for,
// so /covid answered 200 with the whole application in it — and render() reads
// location.hash, which was empty, so it matched "/" and drew the DIRECTORY.
// Measured on the live site: panel:false, input:false. There was no chat box on
// that page. Nothing was broken; the reader was never on the court.
//
// THAT CLASS OF BUG IS INVISIBLE TO EVERY OTHER CHECK HERE. route_crawl follows
// the links the application itself draws, and the application only ever draws
// hash URLs — so the one URL shape a human invents is the one nothing visited.
//
// MEASURED BY BREAKING IT:
//   removing the adopt block      /covid draws the directory: both court arms fail
//   dropping the routes.some()    /diag becomes #/c/diag, an unknown court
//   adopting any path             /m/deadbeef becomes #/c/m/deadbeef
//   using location.replace        the typed URL stays in history (arm below)
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 900});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  /* file:// CANNOT SHOW THE REAL SHAPE. PAGE is a file path ending in
     index.html, so there is no server fallback to imitate and no clean path to
     adopt. The adopting happens at boot from location.pathname, so the honest
     way to exercise it is to boot the page and then run the same decision the
     boot makes, against paths the deployed site really does serve. The
     application's own route table is the input, which is the whole point of the
     rule — a list written in this file would agree with the router on the day it
     was written. */
  await page.goto(PAGE, {waitUntil: 'networkidle2'});
  await new Promise(r => setTimeout(r, 1500));

  /* THE SHIPPED FUNCTION, CALLED — not a copy of it evaluated here. The first
     version of this check re-implemented the three lines in the page's own
     scope, which meant deleting the whole feature from index.html failed only
     the source-reading arms below: the behaviour arms went on passing against a
     copy that lived in this file. pathRoute exists so there is one decision and
     one place to test it. */
  /* AND TOLERANT OF IT BEING ABSENT. Deleting pathRoute outright made every
     arm below throw inside page.evaluate, which killed the process before it
     printed anything — a check that says nothing at all is indistinguishable in
     a log from one that never ran. Now its absence is an ANSWER, and a wrong
     one, so the arms report it. */
  const decide = p => page.evaluate(path =>
    typeof pathRoute === "function" ? pathRoute(path) : "NO pathRoute IN THE PAGE", p);

  /* THE REPORTED URL. A bare segment is a court, because that is what a person
     types when they know the court's name and not the site's route syntax. */
  ok("/covid adopts the court route", await decide("/covid") === "/c/covid",
     JSON.stringify(await decide("/covid")));
  ok("...and a trailing slash makes no difference", await decide("/covid/") === "/c/covid");

  /* A PATH THAT IS ALREADY A ROUTE IS TAKEN AS WRITTEN, and this is decided by
     asking the route table rather than by a list here. Without it /diag would
     be adopted as a COURT called diag, which is a real page for a court that
     does not exist. */
  for (const [p, want] of [["/diag", "/diag"], ["/me", "/me"], ["/about", "/about"],
                           ["/c/covid", "/c/covid"], ["/c/covid/map", "/c/covid/map"],
                           ["/params", "/params"]]) {
    ok(`${p} is already a route and is kept`, await decide(p) === want,
       JSON.stringify(await decide(p)));
  }

  /* AND ANYTHING ELSE IS LEFT ALONE. A deep path with no route is what a missing
     media blob looks like when it falls through to this file, and turning it
     into a court named "m/deadbeef" would replace one wrong page with a
     stranger one. Null means "change nothing", which draws the directory —
     exactly what happens today. */
  for (const p of ["/m/deadbeef", "/api/chat/dev/orem", "/COVID", "/covid/nope/deeper", "/"]) {
    ok(`${p} is left alone`, await decide(p) === null, JSON.stringify(await decide(p)));
  }

  /* THE ADOPTION IS A replaceState AND NOT A REDIRECT. A redirect costs a second
     request for a file the browser already has, and it puts the URL the reader
     typed into their history — so Back returns to the pathname, which adopts
     again, and Back can never leave the page. Checked in the source because the
     behaviour it prevents cannot be observed on file://. */
  const src = require('fs').readFileSync(
    require('path').join(__dirname, '..', '..', 'index.html'), 'utf8');
  /* SLICED ON TWO LITERAL ANCHORS rather than matched with a pattern. A regex
     over this shape needed to know where the function ended and where the if
     block did, and it silently matched nothing when pathRoute was extracted out
     of the block — reporting the feature as missing on a tree that had it. */
  const from = src.indexOf("function pathRoute("), until = src.indexOf("render().then(");
  const boot = from >= 0 && until > from ? src.slice(from, until) : "";
  ok("the boot block is there at all", boot.length > 0, "no adopt block in index.html");
  ok("...and adopts with replaceState, not a redirect",
     /history\.replaceState/.test(boot) && !/location\.(replace|href|assign)/.test(boot),
     boot.slice(0, 200));
  /* AND ONLY WHEN THERE IS NO HASH. A hash URL is the application's own
     navigation and must always win; adopting over one would fight every link on
     the site. */
  ok("...and only when the URL carries no hash of its own",
     /if\(!location\.hash\)/.test(src));
  /* THE QUERY SURVIVES. ?focus=<id> is how a claim page's "map →" says which
     node it meant, and dropping it would silently lose the only argument these
     URLs take. */
  ok("...and keeps the query string", /location\.search/.test(boot), boot.slice(-160));

  /* ---- and the trailing slash, which is a different defect ----------------
     /covid/ resolved to the right route and STILL had no chat panel. The two
     script tags are relative, so the document's own URL decides what they point
     at: at /covid/ the base is /covid/ and chat.js is fetched from
     /covid/chat.js, which nginx answers with the fallback — the page loads
     ITSELF as JavaScript, mountChat never exists, and the court has no chat.
     Measured on the deployed site: panel:false, input:false.
     STRIPPED ABOVE THE SCRIPT TAGS, because by the time the adopt block runs the
     wrong script has already been fetched — so this is checked by POSITION, not
     only by presence. */
  const strip = src.indexOf('/\\/$/.test(location.pathname)');
  const firstTag = src.indexOf('<script src="chat.js">');
  ok("the trailing slash is stripped", strip > 0, "no trailing-slash guard at all");
  ok("...before chat.js is asked for", strip > 0 && firstTag > strip,
     `guard at ${strip}, script tag at ${firstTag}`);
  /* A REAL NAVIGATION, because the base URL is fixed when the document is
     fetched: replaceState would correct the address bar and leave every relative
     src still pointing into /covid/. */
  ok("...with a navigation, since replaceState cannot move the base",
     /location\.replace\(location\.pathname\.replace/.test(src));
  /* AND file:// IS EXEMPT. Every browser check here runs from a file:// path
     ending in index.html; rewriting that would point the page at
     file:///chat.js and take the whole suite out. */
  ok("...and file:// is left alone", /location\.protocol !== "file:"/.test(src));

  ok("the page threw nothing while doing all that", errs.length === 0, errs.join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
