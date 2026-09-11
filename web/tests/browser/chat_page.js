// The chat panel ON THE REAL COURT PAGE.
// check-web-selectors: gone chatdry — the dry-run notice, removed in 6e5c1e1 at the owner's word
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
  /* THE PANEL'S OWN PAGE. It used to be mounted in the rail on every court
     route; it is a view of its own now — "it's probably a bad idea to have chat
     in the sidebar to begin with" — so a harness about the panel visits the
     panel. The wait below still matches: the view's heading is the court's name
     followed by " — chat". */
  /* !== undefined, NOT ||, because the court page's route is the EMPTY string
     and `"" || "/chat"` is "/chat" — so asking for the docket silently got the
     room, and two arms failed on a view that has no docket to be intact. */
  const route = (opts && opts.route !== undefined) ? opts.route : "/chat";
  await page.goto(PAGE + "#/c/orem" + route, {waitUntil: "load"});
  // The heading is the page's own content; waiting for it rather than a fixed delay.
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
      const slot = document.getElementById("chatview");
      const log = slot && slot.querySelector(".chatlog");
      const main = document.getElementById("main");
      /* WHERE IT SITS MATTERS, AND IT HAS MOVED TWICE. First it hung below the
         docket, where a reader had to scroll past every claim to find out
         anyone was talking. Then it went into the rail, visible the whole time
         and costing the court page no height — and that is where it met the
         problem that moved it again: a 230px column sharing its height with the
         navigation and the node controls, where the transcript measured 0px on
         every desktop height from 700 to 900.
         NOW IT IS THE PAGE. So the check inverts: the panel must be INSIDE main,
         and the rail must hold no panel at all. */
      const rail = document.querySelector("aside.rail");
      const inView = !!(slot && main.contains(slot) && !(rail && rail.contains(slot)));
      return {
        mounted: !!log,
        lines: log ? log.querySelectorAll(".chatmsg").length : 0,
        styled: !!document.getElementById("chatcss"),
        tagged: slot ? slot.classList.contains("chatpanel") : false,
        inView,
        text: log ? log.textContent : "",
      };
    });
    /* THE RAIL SAYS THE ROOM IS THERE, and that is all it says now. This block
       used to measure the void between the rail's "Chat" label and the panel
       beneath it — a margin, a padding and a border from two stylesheets that
       only existed on screen. There is no panel in the rail to sit under the
       label; there is a line that links to the room, and what is worth pinning
       is that it names the court it opens. Getting that wrong would look
       identical and open somebody else's room. */
    /* THE ROOM HANGS UNDER THE COURT ON EVERY COURT ROUTE, and what changes with
       where you are is only which row is lit.
       ASKED FOR IN TWO STEPS, and this block was rewritten for each. First the
       room got a trail row while you were inside it; then "CHAT should just be
       under COVID. it is after all a chat *in* the covid court" made it permanent
       — one of the court's children, beside a claim and a folder, present whether
       or not you have walked in. The standalone section at the foot of the nav is
       the fallback for the routes that resolve a room but get no trail: /here and
       /raw/<slug>.
       BY CLASS, NOT BY LABEL. The row carries a count and a dot as well as the
       word, so its text reads "Chatquiet" or "Chat4 here" — matching the label
       cost four failing arms before, and will again the next time the counts
       change wording. .chatrow is what the code puts there on purpose. */
    const railState = () => page.evaluate(() => {
      const h = document.getElementById("railchathead");
      const a = h && h.querySelector("a.railchatlink");
      const rail = document.querySelector("aside.rail") || document.querySelector(".rail");
      const trail = [...document.querySelectorAll("#nav a.trail")].map(t => ({
        label: [...t.childNodes].filter(n => !(n.classList && n.classList.contains("b")))
                 .map(n => n.textContent || "").join("").replace(/\s+/g, " ").trim(),
        chat: /\bchatrow\b/.test(t.className),
        deep: /\bdeep\b/.test(t.className),
        lit: /(^|\s)on(\s|$)/.test(t.className),
        href: t.getAttribute("href"),
      }));
      return {
        lineShown: !!(h && !h.hidden),
        href: a ? a.getAttribute("href") : null,
        panelInRail: !!(rail && rail.querySelector(".chatlog")),
        trail,
      };
    });

    {
      const inRoom = await railState();
      const chatRow = inRoom.trail.find(t => t.chat);
      const courtRow = inRoom.trail.find(t => /OREM/.test(t.label));
      ok("the rail hangs the room under the court",
         !!chatRow && chatRow.deep === true, JSON.stringify(inRoom.trail));
      ok("...linking to the room it names",
         !!chatRow && chatRow.href === "#/c/orem/chat", JSON.stringify(chatRow));
      ok("...lit while you are in it, so the rail says where you are",
         !!chatRow && chatRow.lit === true, JSON.stringify(chatRow));
      /* THE COURT GIVES THE MARKER UP, for the same reason navTrail takes it off
         Directory one level higher: two lit rows claim two places. */
      ok("...while the court above it goes dim",
         !!courtRow && courtRow.lit === false, JSON.stringify(courtRow));
      /* AND THE SECTION IS GONE FROM A COURT ROUTE ENTIRELY, which is the whole
         of the second request: the same line said twice, three groups apart, was
         what "CHAT should just be under COVID" was about. */
      ok("...and the standalone Chat section is not also shown",
         inRoom.lineShown === false, JSON.stringify(inRoom));
      ok("...with no chat panel left in the rail either",
         inRoom.panelInRail === false, JSON.stringify(inRoom));
    }

    {
      await page.evaluate(() => { location.hash = "#/c/orem"; });
      await page.waitForFunction(() => !document.getElementById("chatview"), {timeout: 20000});
      await new Promise(r => setTimeout(r, 700));
      const onCourt = await railState();
      const chatRow = onCourt.trail.find(t => t.chat);
      /* THE ROOM IS STILL THERE WHEN YOU ARE NOT IN IT. This is the arm the
         earlier shape got wrong: it asserted no Chat row on the court page,
         which was right while the row meant "you are here" and is exactly
         backwards now that it means "this court has one". */
      ok("on the court page the room still hangs under the court",
         !!chatRow && chatRow.href === "#/c/orem/chat", JSON.stringify(onCourt.trail));
      ok("...unlit, because you are not in it", !!chatRow && chatRow.lit === false,
         JSON.stringify(chatRow));
      ok("...with the court itself lit instead",
         onCourt.trail.some(t => /OREM/.test(t.label) && t.lit),
         JSON.stringify(onCourt.trail));
      ok("...and still no standalone section duplicating it",
         onCourt.lineShown === false, JSON.stringify(onCourt));
      /* AND NO PANEL BESIDE IT. The whole point of the move is that the rail
         stopped holding a room; a second mount here would put the reader in two
         of them and split the poller between them. */
      ok("...and no chat panel left in the rail", onCourt.panelInRail === false,
         JSON.stringify(onCourt));
      /* AND BACK IN, WHICH IS THE CASE THE CODE ALMOST GOT WRONG. railChatFor
         returns early when the slug has not changed, and court→room→court never
         changes it — so anything that depends on the route rather than the court
         has to happen before that return. Walking the round trip is the only way
         to catch a marker that only moves on a reload. */
      await page.evaluate(() => { location.hash = "#/c/orem/chat"; });
      await page.waitForFunction(
        () => !!document.querySelector("#chatview .chatlog"), {timeout: 20000});
      await new Promise(r => setTimeout(r, 700));
      const again = await railState();
      ok("and the marker moves back to the room on the way in",
         !!again.trail.find(t => t.chat && t.lit)
           && !again.trail.some(t => /OREM/.test(t.label) && t.lit),
         JSON.stringify(again.trail));
    }

    /* THE GLOBE AND THE COURT IT BORROWS, which is the one transition where the
       section has to change state while the SLUG does not.
       /here has no court trail to hang under, so it keeps the standalone
       section, and the room it names is the meta court's — META_SLUG. Walking
       from there to /c/meta therefore goes: same slug, so railChatFor takes its
       early return, but the row state flips from absent to present and the
       section has to stand down anyway.
       MUTATION TESTING IS WHY THIS ARM EXISTS. Deleting the hide that runs
       BEFORE that early return broke nothing any other arm could see — every
       other path either arrives fresh or keeps hasRow constant — and this is the
       only walk in the suite where those two come apart. */
    {
      await page.evaluate(() => { location.hash = "#/here"; });
      await page.waitForFunction(
        () => !document.querySelector("#nav a.trail.chatrow"), {timeout: 20000});
      await new Promise(r => setTimeout(r, 900));
      const globe = await railState();
      ok("the globe has no court to hang the room under",
         !globe.trail.some(t => t.chat), JSON.stringify(globe.trail));
      ok("...so it keeps the standalone section, which is the only way in there",
         globe.lineShown === true && !!globe.href, JSON.stringify(globe));

      await page.evaluate(() => { location.hash = "#/c/meta"; });
      await page.waitForFunction(
        () => !!document.querySelector("#nav a.trail.chatrow"), {timeout: 20000});
      await new Promise(r => setTimeout(r, 900));
      const meta = await railState();
      ok("stepping onto that same court hangs the row", !!meta.trail.find(t => t.chat),
         JSON.stringify(meta.trail));
      ok("...and the section stands down even though the court did not change",
         meta.lineShown === false, JSON.stringify(meta));
    }
    ok("a court page mounts the chat panel", r.mounted);
    ok("...in the page, not in the rail", r.inView);
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
  //
  // route:"" — THE COURT'S OWN PAGE, not the room. This block is about the
  // docket surviving a missing chat.js, and the docket is on the court page;
  // pointing it at /chat asserted the stats and the claim list on a view that
  // has neither, which is how it failed after the panel moved. The room's own
  // behaviour without chat.js is the arm below it.
  {
    const {page, errors} = await courtPage(browser, {blockChatJs: true, route: ""});
    const r = await page.evaluate(() => {
      const main = document.getElementById("main");
      return {
        court: /Orem Truth Court/.test(main.textContent),
        // The court's own substance, not just its heading.
        stats: /coin price/.test(main.textContent),
        docketRows: main.querySelectorAll("a[href*='#/c/orem/']").length,
        // Nothing may be mounted anywhere: the rail no longer holds a slot and
        // the court page never did.
        panel: !!document.querySelector(".chatlog"),
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
    /* ...BETWEEN CHAT ROUTES, because the panel only exists on one. Walking
       court-to-court used to carry the rail's panel along with it; now each hop
       has to land on a room for there to be a panel to leak. */
    for (const slug of ["ledger", "orem", "ledger", "orem"]) {
      await page.evaluate(s => { location.hash = "#/c/" + s + "/chat"; }, slug);
      await page.waitForFunction(s =>
        document.getElementById("main").textContent.includes(s === "orem"
          ? "Orem Truth Court" : "The Ledger of Denver"), {timeout: 20000}, slug);
    }
    const r = await page.evaluate(() => ({
      panels: document.querySelectorAll(".chatlog").length,
      slots: document.querySelectorAll("#chatview").length,
      mounted: !!document.querySelector("#chatview .chatlog"),
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
    // `data:` COUNTS AS LOCAL, and that is not a loosening. This list is here to
    // catch bytes LEAVING THE MACHINE; a data URI carries its own payload inline
    // and cannot contact anything, so it is self-contained by definition — the
    // very property the test exists to defend. Chrome still raises a `request`
    // event for one, which is why it has to be named.
    //
    // The chat panel's sky is a data-URI SVG (see CHATCSS in web/chat.js), so
    // without this the test failed on the most self-contained thing on the page.
    // http:, https: and ws: are deliberately NOT excused: those would be the
    // real thing this is looking for.
    const local = u => u.startsWith("file:") || u.startsWith("data:");
    page.on("request", r => { if (!local(r.url())) external.push(r.url()); });
    // THE ROOM: the panel this block waits for lives on its own page now.
    await page.goto(PAGE + "#/c/orem/chat", {waitUntil: "load"});
    await page.waitForFunction(
      () => !!document.querySelector("#chatview .chatlog"), {timeout: 20000});
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
    // THE ROOM: the panel this block waits for lives on its own page now.
    await page.goto(PAGE + "#/c/orem/chat", {waitUntil: "load"});
    await page.waitForFunction(
      () => !!document.querySelector("#chatview .chatlog"), {timeout: 20000});
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
    // EMPTY, NOT ABSENT, and the difference is the whole reason chat reaches
    // anybody. `undefined` means "no preference", and since 81f93f8 no preference
    // means ON when the page is served from an origin that can host the service.
    // So "off" needs a value of its own — cleanCfg preserves `chat:""` for
    // exactly this, and asserting undefined here would be asserting that turning
    // chat off turns it back on.
    ok("blanking the field turns chat off", cleared.cfg === "");
    ok("...and removes it from storage rather than keeping a stale value",
       !!cleared.raw && !cleared.raw.includes("8791"));
    await page.close();
  }

  // THE DRY-RUN NOTICE IS GONE, at the owner's word: the panel used to tell every
  // reader "Automatic moderation is not applying timeouts on this server right
  // now", which is operator telemetry wearing a safety warning's clothes.
  //
  // Asserted as an ABSENCE rather than deleted, because the slot, its style and
  // its export were all removed — a .chatdry reappearing would mean the notice
  // came back rather than that somebody renamed something.
  {
    const {page, errors} = await courtPage(browser);
    const r = await page.evaluate(() => ({
      dry: !!document.querySelector("#railchat .chatdry"),
      log: !!document.querySelector("#chatview .chatlog"),
    }));
    ok("the panel carries no dry-run notice", r.dry === false);
    ok("...and this is not vacuous — the panel really mounted", r.log === true);
    ok("no errors: " + (errors[0] || "none"), errors.length === 0);
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

  // DEMO MODE MUST NOT TOUCH THE NETWORK, and only a check that loads BOTH files
  // can see this. chat.js has always had the guard — "demo mode means no
  // network" — and chat_test.js has always asserted it, passing, while the page
  // did the opposite: index.html declares its own global `chatBase()` in an
  // inline script evaluated AFTER chat.js, so the later declaration won and the
  // guard was unreachable. Measured before the fix, a demo court page issued
  //
  //     GET http://…/api/chat/health
  //     GET http://…/api/chat/dev/orem?limit=50
  //
  // against sample data. The harness that slices chat.js alone cannot see a
  // collision that needs the other file to exist, which is why this lives here.
  {
    const page = await browser.newPage();
    const asked = [];
    await page.setRequestInterception(true);
    page.on("request", r => {
      const u = r.url();
      if (u.includes("chat.invalid")) { asked.push(u); return r.abort().catch(() => {}); }
      r.continue().catch(() => {});
    });
    await page.evaluateOnNewDocument(() => {
      localStorage.setItem("cc.cfg", JSON.stringify({mode: "demo", chat: "http://chat.invalid:8791"}));
      localStorage.setItem("cc.intro", "1");
    });
    await page.goto(PAGE + "#/c/orem", {waitUntil: "domcontentloaded"});
    await new Promise(r => setTimeout(r, 1800));
    ok("a demo court page asks the chat endpoint for nothing",
       asked.length === 0, asked.slice(0, 2).join(" "));
    await page.close();
  }

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("Error:", e && e.stack || e); process.exit(1); });
