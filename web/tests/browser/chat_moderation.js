// The moderation loop, end to end, with the real model and a real browser.
//
// Everything else stops short of this. chat_live.js applies a consequence with
// kourtchatctl, so it proves the enforcement PATH without ever asking gemma3:4b
// anything. internal/scan's live fixtures ask the model but have no browser. This is
// the whole thing: two people in one court, one of them posts a scam, the scanner reads
// it, and what each of them sees afterwards is checked in the DOM.
//
// THE RULE IT EXISTS FOR: test the BYSTANDER, not just the target. The two worst bugs
// in this service were both invisible to unit tests — every automated kick punished the
// whole /24, and a correct verdict was discarded because gemma3:4b reports confidence
// on a 0-100 scale. Both were found by running the real thing and reading rows. So the
// bystander here is a real second identity with its own browser context, and the
// assertion that matters most is the one about them: they must be untouched.
//
// TWO IDENTITIES IN ONE BROWSER. Everything on this machine is 127.0.0.1, and in proxy
// mode an absent X-Forwarded-For falls through to the peer, so both pages would be one
// client. So kourtchat runs behind two one-line proxies that each inject a different
// forwarded address — which is the deployment shape anyway — and each page gets its own
// browser context so their localStorage does not collide.
//
// Skipped unless OLLAMA_LIVE=1, because it needs a model. `make check` stays hermetic.
//
//   OLLAMA_LIVE=1 node web/tests/browser/chat_moderation.js
const path = require("path");
const fs = require("fs");
const os = require("os");
const net = require("net");
const http = require("http");
const { spawn, spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..", "..", "..");
const MODEL = process.env.OLLAMA_MODEL || "gemma3:4b";
const SCAMMER = "203.0.113.7";
const BYSTANDER = "198.51.100.4";

let fail = 0;
const ok = (n, c) => { if (!c) { fail++; console.log("FAIL:", n); } else console.log("ok:", n); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const freePort = () => new Promise(res => {
  const s = net.createServer();
  s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => res(p)); });
});

// A proxy that speaks for one address. Forwards method, path, headers and body
// unchanged except for the forwarded-for it adds, and copies the response back — the
// CORS and CSRF headers included, since those are the point of going through a browser.
function xffProxy(target, asAddr) {
  return http.createServer((req, res) => {
    const headers = {...req.headers, "x-forwarded-for": asAddr};
    delete headers.host;
    const up = http.request(target + req.url, {method: req.method, headers}, r => {
      res.writeHead(r.statusCode, r.headers);
      r.pipe(res);
    });
    up.on("error", e => { res.writeHead(502); res.end(String(e.message)); });
    req.pipe(up);
  });
}

(async () => {
  if (process.env.OLLAMA_LIVE !== "1") {
    console.log("chat_moderation: set OLLAMA_LIVE=1 to run against a real model. skipping");
    console.log("\nALL PASS");
    process.exit(0);
  }
  let puppeteer;
  try { puppeteer = require("puppeteer"); }
  catch (e) { console.log("chat_moderation: no puppeteer. skipping\n\nALL PASS"); process.exit(0); }
  try {
    const tags = await (await fetch("http://127.0.0.1:11434/api/tags")).json();
    const have = (tags.models || []).map(m => m.name);
    if (!have.some(n => n === MODEL || n.startsWith(MODEL.split(":")[0]))) {
      console.log(`chat_moderation: ${MODEL} not installed (have ${have.join(", ") || "none"}). skipping`);
      console.log("\nALL PASS");
      process.exit(0);
    }
  } catch (e) {
    console.log("chat_moderation: ollama not reachable. skipping\n\nALL PASS");
    process.exit(0);
  }

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "kourtmod-live-"));
  const db = path.join(dir, "chat.db");
  const CHAT = path.join(dir, "kourtchat"), MOD = path.join(dir, "kourtmod");
  for (const [out, pkg] of [[CHAT, "./cmd/kourtchat"], [MOD, "./cmd/kourtmod"]]) {
    const r = spawnSync("go", ["build", "-o", out, pkg],
      {cwd: ROOT, encoding: "utf8", env: {...process.env, GOFLAGS: "-mod=mod"}});
    if (r.status !== 0) { console.log("cannot build " + pkg + ": " + r.stderr); process.exit(1); }
  }

  const port = await freePort();
  const srv = spawn(CHAT, ["--db", db, "--addr", "127.0.0.1:" + port, "--chain", "dev",
    "--behind-proxy", "--trusted-proxy", "127.0.0.0/8"], {stdio: ["ignore", "pipe", "pipe"]});
  const log = [];
  srv.stdout.on("data", d => log.push(String(d)));
  srv.stderr.on("data", d => log.push(String(d)));

  const servers = [srv];
  const httpds = [];
  const cleanup = async () => {
    for (const s of servers) { try { s.kill(); } catch (e) {} }
    for (const h of httpds) { await new Promise(r => h.close(r)); }
    fs.rmSync(dir, {recursive: true, force: true});
  };

  try {
    let up = false;
    for (let i = 0; i < 60 && !up; i++) {
      try { up = (await fetch(`http://127.0.0.1:${port}/api/chat/health`)).ok; }
      catch (e) { await sleep(100); }
    }
    ok("kourtchat is up behind a proxy policy", up);
    if (!up) throw new Error(log.join(""));

    // Two proxies, two identities, and a static server for the page.
    const target = `http://127.0.0.1:${port}`;
    const pScam = await freePort(), pBy = await freePort(), pWeb = await freePort();
    const a = xffProxy(target, SCAMMER), b = xffProxy(target, BYSTANDER);
    const web = http.createServer((req, res) => {
      const f = path.join(ROOT, "web", decodeURIComponent(req.url.split("?")[0]));
      if (!f.startsWith(path.join(ROOT, "web")) || !fs.existsSync(f)) {
        res.writeHead(404); res.end("no"); return;
      }
      const t = {".html": "text/html", ".js": "text/javascript"}[path.extname(f)] || "text/plain";
      res.writeHead(200, {"Content-Type": t}); res.end(fs.readFileSync(f));
    });
    httpds.push(a, b, web);
    await Promise.all([
      new Promise(r => a.listen(pScam, "127.0.0.1", r)),
      new Promise(r => b.listen(pBy, "127.0.0.1", r)),
      new Promise(r => web.listen(pWeb, "127.0.0.1", r)),
    ]);

    const browser = await puppeteer.launch({headless: "new"});
    const errors = [];
    // A separate context per person, so one page's stored moniker and endpoint cannot
    // leak into the other's.
    async function person(chatPort, name) {
      const ctx = await browser.createBrowserContext();
      const page = await ctx.newPage();
      page.on("pageerror", e => errors.push(name + ": " + e));
      page.on("dialog", async d => { errors.push(name + " dialog: " + d.message()); await d.dismiss(); });
      await page.goto(`http://127.0.0.1:${pWeb}/chat-demo.html`, {waitUntil: "load"});
      await page.evaluate(b => {
        document.getElementById("ep").value = b;
        document.getElementById("ch").value = "dev";
        document.getElementById("ct").value = "orem";
        document.getElementById("go").click();
      }, `http://127.0.0.1:${chatPort}`);
      await page.waitForFunction(() =>
        document.querySelector("#livechat .chatlog").textContent.length > 0, {timeout: 20000});
      const say = async body => {
        await page.evaluate((n, t) => {
          document.querySelector("#livechat .chatmoniker").value = n;
          document.querySelector("#livechat .chatinput").value = t;
          document.querySelector("#livechat .chatnote").textContent = "";
          document.querySelector("#livechat .chatform")
            .dispatchEvent(new Event("submit", {cancelable: true}));
        }, name, body);
        await page.waitForFunction(t => {
          const l = document.querySelector("#livechat .chatlog").textContent;
          const nt = document.querySelector("#livechat .chatnote").textContent;
          return l.includes(t) || nt.length > 0;
        }, {timeout: 20000}, body);
        return page.evaluate(() =>
          document.querySelector("#livechat .chatnote").textContent);
      };
      const state = () => page.evaluate(() => ({
        log: document.querySelector("#livechat .chatlog").textContent,
        notice: document.querySelector("#livechat .chatstate").textContent,
        blocked: document.querySelector("#livechat .chatinput").disabled,
      }));
      return {page, say, state};
    }

    const crook = await person(pScam, "crook");
    const nb = await person(pBy, "neighbour");

    // Ordinary traffic first, so there is a bystander in the room BEFORE anything is
    // moderated — and so the model has innocent context around the scam.
    ok("the bystander can post", await nb.say("is the settle window on this one still open?") === "");
    await sleep(2500);   // the 2s per-address floor; different addresses, but be honest
    const scamNote = await crook.say(
      "send me your seed phrase and I will restore your funds, dm me at t.me/kourtsupport");
    ok("the scam is accepted at first — moderation is after the fact, not a filter",
       scamNote === "");

    // The scam reaches the room before anything is scanned. WAITING for it rather than
    // reading immediately, because the bystander's panel refetches on its own interval
    // and the first version of this raced it — and waiting turns the check into the
    // stronger one anyway: it is another client's message arriving without a reload.
    await nb.page.waitForFunction(
      () => /seed phrase/.test(document.querySelector("#livechat .chatlog").textContent),
      {timeout: 30000});
    let s = await nb.state();
    ok("the scam reaches the room before it is scanned, on the poller alone",
       /seed phrase/.test(s.log));
    ok("...and moderation is after the fact rather than a filter", s.blocked === false);

    // ------------------------------------------------------- the real model
    const scan = spawnSync(MOD, ["--db", db, "--model", MODEL, "--once", "--enforce"],
      {encoding: "utf8", timeout: 180000});
    const out = (scan.stdout || "") + (scan.stderr || "");
    console.log("    [scanner] " + (out.trim().split("\n").pop() || "(silent)").slice(0, 150));
    ok("the scanner ran", scan.status === 0);
    const kicked = /kicked/.test(out);
    ok("...and acted on the scam: " + (out.match(/(spam|scam|hack)/) || ["no verdict"])[0],
       kicked);

    // ------------------------------------------------------- what each of them sees
    //
    // Poll rather than sleep a guessed amount: the panel refetches on its own interval.
    if (kicked) {
      await crook.page.waitForFunction(
        () => document.querySelector("#livechat .chatinput").disabled === true,
        {timeout: 30000});
      const c = await crook.state();
      ok("the scammer is told they are paused", /paused|blocked/i.test(c.notice));
      ok("...and cannot type", c.blocked === true);
      ok("...without being told which category, so it is not an evasion oracle",
         !/spam|scam|hack|phish|seed/i.test(c.notice));
      ok("...and their scam is gone from their own view", !/seed phrase/.test(c.log));
    }

    // THE ASSERTION THAT MATTERS MOST. A different address, in the same court, at the
    // same moment. If this fails the way it failed before, it will be because a
    // consequence reached a network rather than an address.
    await nb.page.waitForFunction(
      () => !/seed phrase/.test(document.querySelector("#livechat .chatlog").textContent),
      {timeout: 30000}).catch(() => {});
    s = await nb.state();
    ok("the scam is hidden from the room", !/seed phrase/.test(s.log));
    ok("the bystander is NOT punished", s.blocked === false);
    ok("...is shown no notice at all", s.notice === "");
    ok("...still sees their own message", /settle window/.test(s.log));
    await sleep(2500);
    ok("...and can still post",
       await nb.say("still here, and still able to talk") === "");
    const after = await nb.state();
    ok("...which appears in their panel", /still here/.test(after.log));

    ok("no page errors: " + (errors[0] || "none"), errors.length === 0);
    await browser.close();
  } finally {
    await cleanup();
  }

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("Error:", e && e.stack || e); process.exit(1); });
