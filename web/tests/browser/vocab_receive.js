// YOU DO NOT BUY. YOU BURN, AND YOU RECEIVE.
//
// The owner's call, and the register is a burnt offering: GNOT goes one way to a
// keyless address and the coin comes back. "Buy" carries a seller, a price and a
// way out at that price, and there is none of the three.
//
// MEASURED ON THE RENDERED PAGE, not grepped from the source. The word survives
// legitimately in the file — `Buy` is the realm's entrypoint, and the gnokey
// command this page prints has to name it — so a file-level rule like the one
// dispute_test.js holds over "money" would fail on a true sentence. What matters
// is what a reader sees, so that is what is read: the visible text of the pages
// where coin changes hands, with <pre>/<code> excluded because a command is a
// literal, not copy.
const puppeteer = require('puppeteer');
const path = require('path');
const PAGE = 'file://' + path.join(__dirname, '..', '..', 'index.html');
const ROUTES = ["#/", "#/about", "#/c/orem", "#/c/orem/11", "#/me", "#/needs", "#/c/orem/curate"];

(async () => {
  const browser = await puppeteer.launch({headless: 'new'});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };
  const page = await browser.newPage();
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo"}));
    localStorage.setItem("cc.intro", "1");
  });
  await page.setViewport({width: 1280, height: 1100});

  const seen = [];
  for (const r of ROUTES) {
    await page.goto(PAGE + r, {waitUntil: 'networkidle0'});
    await new Promise(z => setTimeout(z, 700));
    // open every dialog this page can raise: the buy receipt and the helpers
    // live behind them, and that is exactly where the word used to sit
    const hits = await page.evaluate(async () => {
      const opens = [...document.querySelectorAll("[data-help],.helplink")];
      for (const b of opens) { try { b.click(); await new Promise(z => setTimeout(z, 120)); } catch (_) {} }
      const bad = [];
      const walk = root => {
        for (const n of root.childNodes) {
          if (n.nodeType === 1) {
            const t = n.tagName;
            if (t === "PRE" || t === "CODE" || t === "SCRIPT" || t === "STYLE") continue;
            if (n.offsetParent === null && getComputedStyle(n).display === "none") continue;
            walk(n);
          } else if (n.nodeType === 3 && /\b(buy|buys|buying|bought|buyer|purchase[sd]?)\b/i.test(n.nodeValue)) {
            bad.push(n.nodeValue.trim().slice(0, 90));
          }
        }
      };
      walk(document.body);
      return [...new Set(bad)];
    });
    seen.push([r, hits]);
    ok(`${r} never says buy`, hits.length === 0, hits.slice(0, 2).join(" | "));
  }

  /* AND THE WORD THAT REPLACED IT IS ACTUALLY ON THE BUTTON. Checking the page
     for "receive" anywhere passes on a button that says nothing at all — the
     dialogs alone use the word twice — which is how a vocabulary change quietly
     becomes a deletion. So the verb is read off the control it belongs to. */
  await page.goto(PAGE + "#/c/orem", {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 700));
  const says = await page.evaluate(() => {
    const b = document.querySelector("#buyactions .btn.primary") || document.querySelector("#buyactions .btn");
    const t = document.querySelector(".main").innerText;
    return {verb: b ? b.innerText.trim() : null, burn: /\bburn(ed|s|ing)?\b/i.test(t)};
  });
  ok("the button says what you receive", /\bReceive\b/.test(says.verb || ""), JSON.stringify(says.verb));
  ok("...and the page still says the GNOT is burned", says.burn, JSON.stringify(says.burn));

  /* TWO STRINGS THE OFFLINE SAMPLE CANNOT PUT ON SCREEN, pinned against the
     source rather than left to a walk that never reaches them: both belong to a
     reader who holds none of the coin, and the demo reader holds some. The walk
     above is the rule; these two are the exceptions, named so nobody assumes the
     walk covered them. */
  const src = require('fs').readFileSync(path.join(__dirname, '..', '..', 'index.html'), 'utf8');
  ok("the empty-holding row says burn, and what comes back",
     src.includes("burn GNOT on a court's page to receive its coin and take a position"));
  ok("the ballot speaks of coin received, not of buying",
     src.includes("Coin received now counts in the next vote, not this one."));
  /* TWO MORE THE SAMPLE CANNOT REACH, both live-mode only: the quote note is the
     branch taken when a node actually answered the curve read, and the gate fires
     when the button is pressed with the acknowledgement unticked, which demo mode
     does not arm. */
  ok("the quote note speaks of another offering landing first",
     src.includes("if another offering lands first you'll receive fewer units"));
  ok("the acknowledgement gate speaks of the burn, not of buying",
     src.includes("Tick the acknowledgement first — the burn is permanent."));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
