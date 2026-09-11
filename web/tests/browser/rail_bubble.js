// A badge for rooms that are talking, on pages that are not the room.
//
// WHY THIS EXISTS. Asked for as "when there is new chat activity even when i'm
// not on the chat page, show something (a bubble w/ number?) live so i know
// there are people talking" — and the poller that was already here could not
// answer it. railChatFor picks a slug only on /c/, /raw/ and /here, so on the
// directory or About there was no row, no poll, and nothing to show.
//
// THE ROOMS ARE PLANTED, NOT BORROWED. Every arm below drives a synthetic
// payload through request interception. The first cut of this test ran against
// the live service and reported no bubbles — correctly, because the live rooms
// had been quiet for a day, which means it would have passed just as happily
// against a poller that did nothing at all. A badge whose number is a function
// of the payload has to be tested by controlling the payload.
//
// ABLATED, AND ONLY WHAT WAS ACTUALLY RUN IS CLAIMED. Removing the
// railChatMarkSeen from railChatPoll fails "opening the room clears its badge"
// with orem still at 3 — and the About total with it, at 4 instead of 1, which
// is the same defect seen from the other end. Returning [] instead of
// CHATPULSEKNOWN when the rail names no court fails the About arm alone, with no
// total at all.
//
// NOT COVERED, and an earlier version of this comment claimed it was: the wiring
// from navTrail to chatPulseSoon. wake() below calls that entry point directly,
// so cutting navTrail's call leaves every arm here green. That wiring is the fix
// for the first bug this feature had — a sweep that ran before the court rows
// existed and polled nothing — and it is the gap in this file.
const {PAGE} = require('./harness');
const puppeteer = require('puppeteer');

const now = Math.floor(Date.now() / 1000);
/* THREE ROOMS, THREE CASES, named for the demo register's own courts. orem is
   loud and unseen; ledger has one; meta's only message is a day old, which is the
   case that separates "unseen" from "recent" — the count is both, and a room
   nobody has opened for a day must not badge just for existing. */
const ROOMS = {
  orem: {here: 4, now, messages: [1, 2, 3].map(i => ({id: 100 + i, created_at: now - 60 * i, body: 'm' + i}))},
  ledger: {here: 2, now, messages: [{id: 500, created_at: now - 120, body: 'one'}]},
  meta: {here: 1, now, messages: [{id: 900, created_at: now - 86400, body: 'yesterday'}]},
};

/* THE DEMO PAGE HAS NO ENDPOINT, ON PURPOSE. chatEndpoint returns "" when the
   overlay is not configured for a chain, and chatPulseOnce returns early on
   that — which is right in production (the demo must not poll a static file
   server) and leaves nothing to measure here. So the endpoint is granted after
   load and the sweep is asked for explicitly, through the same debounced entry
   point navTrail uses. What this does NOT cover is the wiring from navTrail to
   that entry point; the arm below asserts the sweep reaches the network and
   paints, not who called it. */
const wake = async page => {
  await page.evaluate(() => {
    window.chatEndpoint = () => "http://chat.test";
    if (typeof chatPulseSoon === "function") chatPulseSoon();
  });
  await new Promise(r => setTimeout(r, 1200));
};

const read = () => {
  const out = {};
  document.querySelectorAll('#nav a.trail[href^="#/c/"]').forEach(a => {
    const b = a.querySelector('.railbubble');
    out[a.getAttribute('href').replace('#/c/', '')] = b ? b.textContent : null;
  });
  const d = document.querySelector('#nav a[data-k="dir"] .railbubble');
  out.DIRECTORY = d ? d.textContent : null;
  return out;
};

(async () => {
  const browser = await puppeteer.launch({args: ['--no-sandbox']});
  const page = await browser.newPage();
  const errs = []; page.on('pageerror', e => errs.push(String(e)));
  let hits = 0;
  await page.setRequestInterception(true);
  page.on('request', req => {
    const m = /\/api\/chat\/[^/]+\/([a-z0-9-]+)\?/.exec(req.url());
    if (m && ROOMS[m[1]]) {
      hits++;
      return req.respond({status: 200, contentType: 'application/json',
        headers: {'Access-Control-Allow-Origin': '*'}, body: JSON.stringify(ROOMS[m[1]])});
    }
    req.continue();
  });
  await page.setViewport({width: 1280, height: 950});

  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // ---- the directory, where no poll ran at all before ----------------------
  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await page.evaluate(() => localStorage.clear());
  await page.reload({waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 2500));
  await wake(page);
  const dir = await page.evaluate(read);

  ok(`the directory polls the courts it names (${hits} requests)`, hits > 0, JSON.stringify(dir));
  ok("a loud room carries its count", dir.orem === "3", JSON.stringify(dir));
  ok("...and a quieter one its own", dir.ledger === "1", JSON.stringify(dir));
  /* THE ROOM NOBODY HAS OPENED AND NOBODY IS IN. Its message is a day old, so it
     is unseen but not recent — the pair of conditions railChatCounts has always
     required, and the half that a first cut of that function got wrong. */
  ok("a room quiet for a day badges nothing", dir.meta === null, JSON.stringify(dir));
  /* AND NO TOTAL WHERE THE BREAKDOWN IS SHOWING, or Directory would carry 4
     directly above rows reading 3 and 1. */
  ok("no total on Directory while its own rows show the parts",
     dir.DIRECTORY === null, JSON.stringify(dir));

  // ---- walking into the room ----------------------------------------------
  await page.goto(PAGE + '#/c/orem/chat', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 1500));
  await wake(page);
  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 2000));
  await wake(page);
  const after = await page.evaluate(read);
  /* THIS IS THE ARM THE FIRST IMPLEMENTATION FAILED. railChatFor marks the
     watermark on arrival, but RAILCHATTOP is reset to 0 by the route change and
     only filled when the poll returns — so on a first visit it marked nothing
     and the badge survived being read. */
  ok("opening the room clears its badge", after.orem === null, JSON.stringify(after));
  ok("...and leaves the other rooms alone", after.ledger === "1", JSON.stringify(after));

  // ---- a page that is not a court at all -----------------------------------
  await page.goto(PAGE + '#/about', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 1500));
  await wake(page);
  const about = await page.evaluate(read);
  ok("About hangs no court rows", Object.keys(about).filter(k => k !== 'DIRECTORY').length === 0,
     JSON.stringify(about));
  /* SO THE TOTAL IS ALL THERE IS TO SHOW, and it has to survive a rail that
     names no court: the slug set is remembered from the last rail that did. */
  ok("...so the total hangs on Directory instead", about.DIRECTORY === "1", JSON.stringify(about));

  ok("nothing threw while doing all that", errs.length === 0, errs.slice(0, 2).join(" | "));
  await browser.close();
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
