// The chat panel in a real browser.
//
// WHY THIS IS NOT A DUPLICATE of web/tests/chat_test.js. That harness asserts things
// about the STRING chat.js produces — `!/<img/.test(html)` and friends. That is a
// regex over source, and it is evidence about a regex. The property that actually
// matters is that a browser's parser does not build an element and no handler runs,
// and the only thing that can demonstrate that is a browser.
//
// It also measures layout, which no source check can: a 400-character message from
// somebody with a 24-character name must not push a court page sideways.
//
//   node web/tests/browser/chat_render.js
const puppeteer = require("puppeteer");
const path = require("path");

const PAGE = "file://" + path.join(__dirname, "..", "..", "chat-demo.html");

let fail = 0;
const ok = (n, c) => { if (!c) { fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

(async () => {
  const browser = await puppeteer.launch({headless: "new"});
  const page = await browser.newPage();

  // Anything the page throws, and any dialog it opens, is a failure. An alert() is
  // the classic proof of execution, and a dialog left unhandled would hang the run.
  const errors = [];
  page.on("pageerror", e => errors.push(String(e)));
  page.on("dialog", async d => { errors.push("dialog: " + d.message()); await d.dismiss(); });

  await page.goto(PAGE, {waitUntil: "load"});
  await page.setViewport({width: 900, height: 800});

  // ---------------------------------------------------------------- demo panel
  {
    const r = await page.evaluate(() => {
      const log = document.querySelector("#demochat .chatlog");
      return {
        mounted: !!log,
        lines: log ? log.querySelectorAll(".chatmsg").length : 0,
        text: log ? log.textContent : "",
        styled: !!document.getElementById("chatcss"),
        // The panel must be tagged, or none of its own CSS applies.
        tagged: document.getElementById("demochat").classList.contains("chatpanel"),
        // getComputedStyle proves the stylesheet is not merely present but matching.
        scrolls: log ? getComputedStyle(log).overflowY : "",
      };
    });
    ok("the panel mounts", r.mounted);
    ok("the sample thread renders", r.lines === 4);
    ok("names are visible", /ellery/.test(r.text) && /tosh/.test(r.text));
    ok("the stylesheet is installed", r.styled);
    ok("the container is tagged", r.tagged);
    ok("the transcript is scrollable rather than unbounded", r.scrolls === "auto");
  }

  // A flag must actually be a flag: two regional indicators, which is four UTF-16
  // units, not the two letters of the country code.
  {
    const r = await page.evaluate(() => {
      const f = document.querySelector("#demochat .chatflag");
      return {present: !!f, text: f ? f.textContent : "",
              units: f ? f.textContent.length : 0,
              cps: f ? [...f.textContent].length : 0,
              title: f ? f.getAttribute("title") : ""};
    });
    ok("a flag renders", r.present);
    ok("...as a regional-indicator pair, not two letters", r.units === 4 && r.cps === 2);
    ok("...with the country code as its title", r.title === "GB");
    ok("...and not as the literal letters", !/^GB$/.test(r.text));
  }

  // ---------------------------------------------------------------- THE ONE THAT MATTERS
  // A hostile body, rendered by the shipped function into a real document. The
  // demo page seeds the box with a payload; this drives it with several more.
  {
    const payloads = [
      '<img src=x onerror="window.__pwned=1">',
      '<script>window.__pwned=1<\/script>',
      '<svg onload="window.__pwned=1"></svg>',
      '<iframe src="javascript:window.__pwned=1"></iframe>',
      '<a href="javascript:window.__pwned=1">click</a>',
      '"><img src=x onerror="window.__pwned=1">',
      "'><img src=x onerror='window.__pwned=1'>",
      '<img src=x onerror=`window.__pwned=1`>',
      '</span></li><img src=x onerror="window.__pwned=1">',
      '<style>body{display:none}</style>',
      '<object data="javascript:window.__pwned=1"></object>',
      '<body onload="window.__pwned=1">',
    ];
    for (const p of payloads) {
      const r = await page.evaluate(payload => {
        delete window.__pwned;
        const out = document.getElementById("evilout");
        out.innerHTML = chatLogHtml([{id: 1, moniker: payload, body: payload,
          country: "DE", suffix: "a1b2c3", created_at: Math.floor(Date.now() / 1000)}],
          Math.floor(Date.now() / 1000));
        return {
          live: out.querySelectorAll(
            "script,img,iframe,svg,object,embed,a,style,link,form,input").length,
          pwned: window.__pwned !== undefined,
          // The payload must still be READABLE. An escaper that dropped it would
          // pass every absence check above while quietly censoring the room.
          shown: out.textContent.includes(payload),
        };
      }, p);
      const label = p.length > 34 ? p.slice(0, 34) + "…" : p;
      ok("no element is built from " + JSON.stringify(label), r.live === 0);
      ok("...nothing executed", !r.pwned);
      ok("...and it is still legible as text", r.shown);
    }
  }

  // Attribute breakout, checked structurally rather than by absence: the moniker
  // must land as TEXT inside .chatname and contribute no attributes to it.
  {
    const r = await page.evaluate(() => {
      const out = document.getElementById("evilout");
      out.innerHTML = chatLogHtml([{id: 1, moniker: '" onmouseover="window.__pwned=1',
        body: "hi", country: "DE", suffix: "a1b2c3",
        created_at: Math.floor(Date.now() / 1000)}], Math.floor(Date.now() / 1000));
      const name = out.querySelector(".chatname");
      return {attrs: name ? name.getAttributeNames() : ["missing"],
              text: name ? name.textContent : ""};
    });
    // Exactly {class} — stronger than looking for `onmouseover` by name, which would
    // pass for any breakout that chose a different attribute. The span has a class of
    // its own, so zero is the wrong expectation; one, and that one, is the right one.
    ok("a quoted moniker contributes no attribute of its own",
       r.attrs.length === 1 && r.attrs[0] === "class");
    ok("...and survives as text", r.text.includes('" onmouseover="'));
  }

  // THE INVARIANT THAT MAKES QUOTE-ESCAPING UNREACHABLE, pinned so it stays true.
  //
  // Deleting the ", ' and ` escapes from chatEsc changes nothing today, and that is a
  // fact about the markup rather than about the escaper: every user-controlled value
  // lands in TEXT position. The one attribute built from message data is the flag's
  // title, and it only renders when the country already matched /^[A-Z]{2}$/. So the
  // quote escapes are defence for a future edit, not a live hole.
  //
  // Testing "quotes are escaped" would therefore pin a mechanism nothing depends on.
  // What is worth pinning is the reason: no attribute value anywhere in a rendered
  // line derives from the message. Put a sentinel in every field and look for it in
  // every attribute of every element — if someone later writes title="${moniker}",
  // this fails and makes them prove the escaping covers it.
  {
    const r = await page.evaluate(() => {
      const S = "SENT1NEL";
      const out = document.getElementById("evilout");
      out.innerHTML = chatLogHtml([{id: 1,
        moniker: '"' + S, body: "'" + S, suffix: "`" + S, country: '"' + S,
        created_at: Math.floor(Date.now() / 1000)}], Math.floor(Date.now() / 1000));
      const found = [];
      for (const el of out.querySelectorAll("*")) {
        for (const a of el.getAttributeNames()) {
          if (String(el.getAttribute(a)).includes(S)) found.push(el.tagName + "@" + a);
        }
      }
      return {found, text: out.textContent.includes(S)};
    });
    ok("no attribute value is derived from a message: " + (r.found.join(",") || "none"),
       r.found.length === 0);
    // The complement, so the check above cannot pass by rendering nothing at all.
    ok("...while the message content itself is still rendered", r.text);
  }

  // No anchors, ever — including from the demo page's own seeded lure.
  {
    const r = await page.evaluate(() => {
      const out = document.getElementById("evilout");
      out.innerHTML = chatLogHtml([{id: 1, moniker: "crook", suffix: "a1b2c3", country: "",
        body: "free airdrop at http://gnot-claim.xyz connect your wallet",
        created_at: Math.floor(Date.now() / 1000)}], Math.floor(Date.now() / 1000));
      return {anchors: out.querySelectorAll("a").length, text: out.textContent};
    });
    ok("a URL never becomes a link", r.anchors === 0);
    ok("...but is readable, so a person can judge it", /gnot-claim\.xyz/.test(r.text));
  }

  // ---------------------------------------------------------------- layout
  // A long body from a long name must not widen the page. This is the check that
  // needs a browser: a source review of the CSS cannot see it.
  {
    for (const width of [1200, 760, 380]) {
      await page.setViewport({width, height: 800});
      const r = await page.evaluate(() => {
        const out = document.getElementById("evilout");
        out.innerHTML = chatLogHtml([
          {id: 1, moniker: "w".repeat(24), suffix: "a1b2c3", country: "JP",
           body: "z".repeat(400), created_at: Math.floor(Date.now() / 1000)},
          {id: 2, moniker: "x".repeat(24), suffix: "b2c3d4", country: "BR",
           body: "https://" + "y".repeat(380), created_at: Math.floor(Date.now() / 1000)},
        ], Math.floor(Date.now() / 1000));
        return {doc: document.documentElement.scrollWidth,
                win: window.innerWidth,
                row: out.querySelector(".chatmsg").getBoundingClientRect().width};
      });
      ok("no horizontal overflow at " + width + "px", r.doc <= r.win + 1);
      ok("...and a 400-character line stays inside the panel at " + width + "px",
         r.row <= r.win + 1);
    }
    await page.setViewport({width: 900, height: 800});
  }

  // ---------------------------------------------------------------- composer
  {
    const r = await page.evaluate(() => {
      const f = document.querySelector("#demochat .chatform");
      const b = document.querySelector("#demochat .chatinput");
      const n = document.querySelector("#demochat .chatmoniker");
      return {form: !!f, maxBody: b && b.getAttribute("maxlength"),
              maxName: n && n.getAttribute("maxlength"),
              enabled: b && !b.disabled};
    });
    ok("there is a composer", r.form);
    ok("the body length matches the server's limit", r.maxBody === "400");

    // THE MONIKER'S maxlength IS DELIBERATELY LOOSER THAN ITS LIMIT, and this assertion used
    // to demand they were equal.
    //
    // The limit counts LETTERS, because in Hebrew, Arabic and Thai a letter costs two or three
    // code points: an eighteen-letter voweled Arabic name is 34 of them. `maxlength` counts
    // UTF-16 units and stops the keystroke with no message at all, so setting it to 24 meant
    // such a name could not be TYPED — a dead key rather than an explanation. It is a crude
    // paste bound now, and chatValidate is what enforces the real limit.
    //
    // Kept as an assertion rather than deleted because "looser" must still mean bounded and
    // derived: an arbitrary large number here would let a paste through to a 400 reply.
    ok("the moniker's maxlength is looser than its letter limit, so a marked name can be typed",
       Number(r.maxName) > 24);
    ok("...and still a bounded multiple of it, not an arbitrary number",
       Number(r.maxName) % 24 === 0 && Number(r.maxName) <= 24 * 8);

    // The half that actually enforces it, called in the page rather than inferred from markup.
    const lim = await page.evaluate(() => {
      const marked = "\u05d1\u05bc\u05b6".repeat(24);   // 24 Hebrew letters, 72 code points
      const plain = "a".repeat(25);                       // 25 Latin letters
      return {
        marked: typeof chatValidate === "function" ? chatValidate(marked, "hello there") : "no fn",
        plain: typeof chatValidate === "function" ? chatValidate(plain, "hello there") : "no fn",
      };
    });
    ok("24 letters of pointed Hebrew is accepted however many code points that is",
       lim.marked === null || lim.marked === undefined || lim.marked === "");
    ok("25 letters is refused, and the message says letters",
       typeof lim.plain === "string" && /too long/.test(lim.plain) && /letter/.test(lim.plain));
    ok("an unpunished reader can type", r.enabled);
  }

  // Submitting in demo mode must say so rather than reaching the network. The page is
  // on file://, so a fetch would be visible as a request; none may be made.
  {
    let requests = 0;
    page.on("request", req => { if (!req.url().startsWith("file:")) requests++; });
    await page.evaluate(() => {
      document.querySelector("#demochat .chatmoniker").value = "alice";
      document.querySelector("#demochat .chatinput").value = "hello";
      document.querySelector("#demochat .chatform")
        .dispatchEvent(new Event("submit", {cancelable: true}));
    });
    const note = await page.evaluate(() =>
      document.querySelector("#demochat .chatnote").textContent);
    ok("demo mode says it is a demo instead of posting", /demo/i.test(note));
    ok("demo mode makes no network request at all", requests === 0);
  }

  ok("the page threw nothing and opened no dialog: " + (errors[0] || "none"),
     errors.length === 0);

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log("Error:", e && e.message); process.exit(1); });
