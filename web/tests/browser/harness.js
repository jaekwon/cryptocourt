// The browser every map check opens, in one place.
//
// check-browser-checks: not-a-check — a helper the checks require; it asserts
// nothing itself, so putting it in a CHECKS list would add a green line for no
// work done. Declared rather than left to be noticed, because
// check-browser-checks-registered correctly flags any file here that no runner
// runs, and that guard was broken and unwired for a long time (607e0b3) —
// silencing it with an undeclared exemption is how that started.
//
// WHY IT EXISTS. map_boing.js, map_draws.js and map_type.js opened with FIFTEEN
// identical lines: the same require pair, the same file:// PAGE, the same
// launch, the same pageerror collector, the same demo-mode localStorage, the
// same viewport call (1440x950 for two of them, 1400x1100 for map_draws, which
// is where the identical run ended).
//
// THE localStorage PAIR IS INSURANCE, NOT LOAD-BEARING, and that is measured
// rather than assumed. Dropping BOTH lines, then each alone, leaves all three
// checks passing with byte-identical measurement counts (6 / 38 / 27). The
// reason is that CFG_DEFAULTS.mode is already "demo" and a fresh puppeteer
// profile has empty localStorage, so the page boots in demo mode with or
// without the setting; and cc.intro suppresses an overlay the map route never
// shows. They are kept so these checks do not silently depend on that default —
// flip CFG_DEFAULTS to "live" and, without them, all three would quietly read
// an empty court and go on passing — but nobody should believe they are doing
// work today. The first version of this comment claimed they were; the ablation
// that was supposed to prove it did not fire.
//
// WHAT IS DELIBERATELY NOT SHARED: each check's own `fail` counter and `ok()`.
// They are two lines, and they are wired to that file's exit path — process
// exit codes, and in one case an uncaughtException hook that decides whether
// reaching the end counts. Sharing the setup is boilerplate removal; sharing the
// verdict would be rewriting how each check reports, for no gain.
const puppeteer = require('puppeteer');
const path = require('path');

const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');

// A browser on a blank page, already told to be in demo mode, already
// collecting page errors. The caller navigates.
//
// DEMO MODE IS SET BEFORE THE FIRST DOCUMENT, via evaluateOnNewDocument, not
// after a goto: the overlay reads cc.cfg while booting, so setting it later
// gives a page that has already decided it is live.
async function demoPage(opts) {
  const {width = 1440, height = 950, deviceScaleFactor} = opts || {};
  const browser = await puppeteer.launch({headless: 'new'});
  const page = await browser.newPage();
  const errs = [];
  page.on('pageerror', e => errs.push(String(e).slice(0, 200)));
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await page.setViewport(deviceScaleFactor
    ? {width, height, deviceScaleFactor}
    : {width, height});
  return {browser, page, errs};
}

module.exports = {PAGE, demoPage};
