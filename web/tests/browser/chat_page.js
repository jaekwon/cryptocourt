// The chat panel ON THE REAL COURT PAGE.
//
// chat_render.js tests the panel in isolation and chat_live.js tests it against a
// server. Neither touches index.html, and the wiring there is where the interesting
// failures live: it is one 20k-line document, its render() is async and re-entrant, and
// the panel is loaded from the only external file the page has ever had.
//
// THE CLAIM THIS FILE EXISTS FOR. web/README.md promises three times over that
// index.html is self-contained — "no build, no dependencies, no server needed", "just
// share the file". Adding chat.js has to leave that true, so the panel is loaded
// optionally and every call into it is guarded on typeof. That is a claim about what
// happens when a file is MISSING, which is not a thing source review establishes and
// not a thing the string-slicing harnesses can see. So it is measured: the court page
// is rendered with chat.js blocked at the network layer, and the docket must survive.
//
//   node web/tests/browser/chat_page.js
const puppeteer = require("puppeteer");
const path = require("path");

const PAGE = "file://" + path.join(__dirname, "..", "..", "index.html");

let fail = 0;
const ok = (n, c) => { if (!c) { fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

async function courtPage(browser, opts) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(String(e)));
  page.on("dialog", async d => { errors.push("dialog: " + d.message()); await d.dismiss(); });
  if (opts && opts.blockChatJs) {
    await page.setRequestInterception(true);
    page.on("request", r => r.url().endsWith("/chat.js") ? r.abort() : r.continue());
  }
  await page.goto(PAGE + "#/c/orem", {waitUntil: "load"});
  // The docket is the page's own content; waiting for it rather than a fixed delay.
  await page.waitForFunction(
    () => /Orem Truth Court/.test(document.getElementById("main").textContent),
    {timeout: 20000});
  return {page, errors};
}

(async () => {
  const browser = await puppeteer.launch({headless: "new"});

  // ---------------------------------------------------------------- the panel is there
  {
    const {page, errors} = await courtPage(browser);
    const r = await page.evaluate(() => {
      const slot = document.getElementById("courtchat");
      const log = slot && slot.querySelector(".chatlog");
      const main = document.getElementById("main");
      // Where it sits matters: the request was "the bottom of each court page", and a
      // panel above the docket would push the court's own content down.
      const docket = main.querySelector("table, .docket, section");
      const below = slot && docket &&
        slot.getBoundingClientRect().top >= docket.getBoundingClientRect().top;
      return {
        mounted: !!log,
        lines: log ? log.querySelectorAll(".chatmsg").length : 0,
        styled: !!document.getElementById("chatcss"),
        tagged: slot ? slot.classList.contains("chatpanel") : false,
        below: !!below,
        text: log ? log.textContent : "",
      };
    });
    ok("a court page mounts the chat panel", r.mounted);
    ok("...at the foot of the court, below its own content", r.below);
    ok("...with the demo sample rather than an empty box", r.lines === 4);
    ok("...and the sample is legible", /ellery/.test(r.text));
    ok("...with the panel's stylesheet installed", r.styled);
    ok("...and the container tagged", r.tagged);
    ok("no page errors: " + (errors[0] || "none"), errors.length === 0);
    await page.close();
  }

  // ---------------------------------------------------------------- THE PROMISE
  // chat.js blocked. The court page must be whole: the README's "no dependencies" is
  // a promise about this exact case, and an unguarded mountChat call would throw
  // mid-paint and take the docket with it.
  {
    const {page, errors} = await courtPage(browser, {blockChatJs: true});
    const r = await page.evaluate(() => {
      const main = document.getElementById("main");
      return {
        court: /Orem Truth Court/.test(main.textContent),
        // The court's own substance, not just its heading.
        stats: /coin price/.test(main.textContent),
        docketRows: main.querySelectorAll("a[href*='#/c/orem/']").length,
        // The slot may exist; what must NOT exist is a mounted panel.
        panel: !!document.querySelector("#courtchat .chatlog"),
        mountFn: typeof window.mountChat,
      };
    });
    ok("with chat.js missing, mountChat is genuinely absent", r.mountFn === "undefined");
    ok("...the court page still renders", r.court);
    ok("...with its statistics intact", r.stats);
    ok("...and its docket intact, so the paint completed", r.docketRows > 0);
    ok("...and no chat panel is mounted", r.panel === false);
    ok("...and nothing threw: " + (errors[0] || "none"), errors.length === 0);
    await page.close();
  }

  // ---------------------------------------------------------------- re-entrant render
  // Navigating court to court must not leave a poller writing into a detached panel.
  // The page's render() is async and re-entrant — this is the case CHATSTOP and
  // mountChat's generation counter both exist for.
  {
    const {page, errors} = await courtPage(browser);
    const before = await page.evaluate(() => typeof CHATSTOP);
    ok("the page holds a stop handle for the panel", before === "function");
    for (const slug of ["ledger", "orem", "ledger", "orem"]) {
      await page.evaluate(s => { location.hash = "#/c/" + s; }, slug);
      await page.waitForFunction(s =>
        document.getElementById("main").textContent.includes(s === "orem"
          ? "Orem Truth Court" : "The Ledger of Denver"), {timeout: 20000}, slug);
    }
    const r = await page.evaluate(() => ({
      panels: document.querySelectorAll(".chatlog").length,
      slots: document.querySelectorAll("#courtchat").length,
      mounted: !!document.querySelector("#courtchat .chatlog"),
      // One id, one panel: a leak would show as several.
      styles: document.querySelectorAll("#chatcss").length,
    }));
    ok("four navigations leave exactly one panel", r.panels === 1);
    ok("...one container", r.slots === 1);
    ok("...still mounted and live", r.mounted);
    ok("...and exactly one stylesheet, however many mounts", r.styles === 1);
    ok("no errors across the navigations: " + (errors[0] || "none"), errors.length === 0);
    await page.close();
  }

  // ---------------------------------------------------------------- demo mode is silent
  // The README promises demo mode makes NO network calls. Chat is the easiest way to
  // break that, since it is the one feature that talks to something other than a node.
  {
    const page = await browser.newPage();
    const external = [];
    page.on("request", r => { if (!r.url().startsWith("file:")) external.push(r.url()); });
    await page.goto(PAGE + "#/c/orem", {waitUntil: "load"});
    await page.waitForFunction(
      () => !!document.querySelector("#courtchat .chatlog"), {timeout: 20000});
    // Give a poller a chance to fire if one were wrongly running.
    await new Promise(r => setTimeout(r, 1500));
    ok("demo mode makes no network call at all: " + (external[0] || "none"),
       external.length === 0);
    await page.close();
  }

  // ---------------------------------------------------------------- the setting persists
  //
  // cleanCfg is a WHITELIST: it rebuilds the config from defaults and copies across only
  // the keys it knows, so a field missing from it is silently forgotten on save. A
  // settings box that takes an endpoint and loses it is worse than no box, and this is
  // the only test that can see the difference — the demo-mode checks above never save a
  // config, which is why deleting the whitelist entry survived them.
  {
    const page = await browser.newPage();
    await page.goto(PAGE + "#/c/orem", {waitUntil: "load"});
    await page.waitForFunction(
      () => !!document.querySelector("#courtchat .chatlog"), {timeout: 20000});
    const saved = await page.evaluate(() => {
      const el = document.getElementById("chat");
      if (!el) return {missing: true};
      el.value = "http://127.0.0.1:8791";
      el.onchange();
      let raw = null;
      try { raw = localStorage.getItem("cc.cfg"); } catch (e) {}
      return {missing: false, cfg: CFG.chat, raw: raw};
    });
    ok("the rail has a chat endpoint field", !saved.missing);
    ok("...which reaches CFG", saved.cfg === "http://127.0.0.1:8791");
    ok("...and survives cleanCfg's whitelist into storage",
       !!saved.raw && saved.raw.includes("127.0.0.1:8791"));

    // And back again: a reload must repopulate it, which is the half a user notices.
    await page.reload({waitUntil: "load"});
    await page.waitForFunction(() => !!document.getElementById("chat"), {timeout: 20000});
    const after = await page.evaluate(() => ({
      field: document.getElementById("chat").value, cfg: CFG.chat}));
    ok("...and is still there after a reload", after.field === "http://127.0.0.1:8791"
       && after.cfg === "http://127.0.0.1:8791");

    // Blank clears it. That is how chat is turned off, and it must not leave a stale
    // endpoint behind in storage.
    const cleared = await page.evaluate(() => {
      const el = document.getElementById("chat");
      el.value = "";
      el.onchange();
      let raw = null;
      try { raw = localStorage.getItem("cc.cfg"); } catch (e) {}
      return {cfg: CFG.chat, raw: raw};
    });
    ok("blanking the field turns chat off", cleared.cfg === undefined);
    ok("...and removes it from storage rather than keeping a stale value",
       !!cleared.raw && !cleared.raw.includes("8791"));
    await page.close();
  }

  // ---------------------------------------------------------------- esc(), hardened
  // The page's own escaper, checked here because it lives in index.html and the change
  // to it was made for chat's sake. Sliced the way the sibling harnesses do.
  {
    const src = require("fs").readFileSync(
      path.join(__dirname, "..", "..", "index.html"), "utf8");
    const line = src.split("\n").find(l => l.startsWith("function esc(s)"));
    ok("esc() is where it was expected", !!line);
    const esc = eval("(" + line.replace(/^function esc/, "function") + ")");
    ok("esc escapes the original four",
       esc('&<>"') === "&amp;&lt;&gt;&quot;");
    ok("esc now escapes a single quote", esc("it's") === "it&#39;s");
    ok("esc now escapes a backtick", esc("a`b") === "a&#96;b");
    ok("esc leaves ordinary text alone", esc("Orem Truth Court") === "Orem Truth Court");
  }

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("Error:", e && e.stack || e); process.exit(1); });
