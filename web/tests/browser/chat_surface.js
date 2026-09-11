// WHAT IS PINNED MUST NOT BE PAINTED AS BACKDROP.
//
// THE REPORT, VERBATIM: "it's strange how the chat has padding around it. also the
// dimissable 'names are unverified...'. it doesn't make sense that it should be both
// transparent (see stars behind it) and it occludes scrolled chat" — and then, on
// being asked: "i'm not saying it actually occludes anything, it's hard to explain.
// it's as if it occludes something because it is 'sticky' as compared to the chat
// scroll below, and yet it is also transparent supposedly at the same time".
//
// Nothing was overlapping. The panel is a flex column and the warning is a static
// block above the log; no z-index, no position, nothing to occlude with. The defect
// was that the panel told the eye two incompatible things. Only .chatlog scrolls, so
// the head above it and the composer below it HOLD STILL while text slides between
// them — which is how a layer behaves. And the starfield was painted on the whole
// panel, so those same held-still bands were painted as though they were the
// backdrop — which is how a background behaves. Constellation lines ran through the
// box you type into. Held like a layer, painted like a background: read as occluding.
//
// SO THE INVARIANT IS A RELATIONSHIP, NOT A COLOUR, and that is what these arms
// measure. The sky belongs to the one region that moves. Nothing above or below it
// may have sky behind it — not the band itself and not any ancestor of it, which is
// the form the bug actually took: .chathead was always transparent and always will
// be, and it was the PANEL underneath that carried the plate.
//
// WHY A BROWSER. Every arm here is either a used value (an inherited font-size times
// a rem), a painted-ancestor walk, or two rectangles' edges. None of the three is a
// string in the stylesheet, and the last one is the reason the margin-to-padding
// conversion is load-bearing rather than tidying: a margin between two opaque bands
// is a gap that shows whatever is behind the panel, and before the plate moved, what
// was behind the panel was stars.
//
//   node web/tests/browser/chat_surface.js
const puppeteer = require("puppeteer");
const path = require("path");

const PAGE = "file://" + path.join(__dirname, "..", "..", "index.html");

let fail = 0;
const ok = (n, c) => { if (!c) { fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

(async () => {
  const browser = await puppeteer.launch({args: ["--no-sandbox"]});
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(String(e)));
  await page.setViewport({width: 1100, height: 900});
  await page.goto(PAGE + "#/c/orem/chat", {waitUntil: "load"});
  await page.waitForFunction(
    () => !!document.querySelector("#chatview .chatform .chatinput"), {timeout: 20000});
  // The log fills on a tick after mount; the arms below read its box.
  await page.waitForFunction(
    () => {
      const l = document.querySelector("#chatview .chatlog");
      return l && l.getBoundingClientRect().height > 40;
    }, {timeout: 20000});

  const m = await page.evaluate(() => {
    const q = s => document.querySelector("#chatview " + s);
    const cs = e => getComputedStyle(e);
    const plated = e => /base64/.test(cs(e).backgroundImage);
    const box = e => e.getBoundingClientRect();
    const panel = document.getElementById("chatview");

    /* THE WALK IS THE TEST. A band is safe when no painted surface from it up to
       the panel carries a plate — which is exactly the check that fails if the
       plate ever moves back onto .chatpanel, and exactly the check that reading
       the band's own background-color cannot make. */
    const skyBehind = el => {
      for (let n = el; n; n = n.parentElement) {
        if (plated(n)) return true;
        if (n === panel) break;
      }
      return false;
    };
    /* THREE COMPONENTS MEANS OPAQUE. The first cut of this matched the last
       number in the string, so `rgb(10, 10, 20)` reported an alpha of 20 and the
       arm failed on a panel that was already opaque — the test was wrong, not
       the CSS. Chromium serialises an opaque colour as rgb() with no fourth
       component at all, so the count is the check. */
    const alpha = e => {
      const c = cs(e).backgroundColor;
      const parts = (/\(([^)]*)\)/.exec(c) || [, ""])[1].split(",");
      return parts.length < 4 ? 1 : Number(parts[3]);
    };

    const head = q(".chathead"), log = q(".chatlog"), form = q(".chatform"),
          note = q(".chatnote"), warn = q(".chatwarn"), input = q(".chatinput");
    const rows = [...document.querySelectorAll("#chatview .chatlog .chatmsg")];
    return {
      // 1. the sky is behind the thing that moves, and only that
      logHasSky: plated(log),
      panelHasSky: plated(panel),
      skyBehindHead: skyBehind(head),
      skyBehindForm: skyBehind(form),
      skyBehindInput: skyBehind(input),
      skyBehindNote: skyBehind(note),
      panelOpaque: alpha(panel) === 1,

      /* 2. THE BANDS MEET THE LOG WITH NO SEAM EITHER SIDE OF IT.
         Not log-to-form: .chatstate and .chathere sit between them, and the
         first cut asserted log.top === form.top and failed by 22px on a room
         that was correct — .chathere was in the gap saying "3 here". So the arm
         is the log's edge against whatever is actually next to it, which is
         what the two hairlines are drawn on. */
      headToLog: Math.round(box(log).top - box(head).bottom),
      logToNext: (() => {
        const vis = [...panel.children].filter(e => box(e).height > 0);
        const i = vis.indexOf(log);
        return i >= 0 && i + 1 < vis.length
          ? Math.round(box(vis[i + 1]).top - box(log).bottom) : null;
      })(),
      /* AND THE WHOLE COLUMN TILES: every visible band starts where the one
         above it ended. One number for the worst seam in the panel, so a margin
         reintroduced anywhere in the stack shows up here rather than in whichever
         single pair the arms happened to name. */
      worstSeam: (() => {
        const vis = [...panel.children].filter(e => box(e).height > 0);
        let worst = 0;
        for (let i = 1; i < vis.length; i++) {
          const g = Math.abs(box(vis[i]).top - box(vis[i - 1]).bottom);
          if (g > worst) worst = g;
        }
        return Math.round(worst);
      })(),

      // 3. the scrolling region says where it starts and ends
      headRule: parseFloat(cs(head).borderBottomWidth),
      logRule: parseFloat(cs(log).borderBottomWidth),

      // 4. the panel is a surface with edges, not a widget wedged under content
      panelBorder: parseFloat(cs(panel).borderTopWidth),
      panelRadius: parseFloat(cs(panel).borderTopLeftRadius),
      panelPadTop: parseFloat(cs(panel).paddingTop),

      // 5. one inset down one edge: the notice and the messages start together
      warnLeft: Math.round(box(warn).left),
      rowLeft: rows.length ? Math.round(box(rows[0]).left) : -1,
      inputBandLeft: Math.round(box(form).left + parseFloat(cs(form).paddingLeft)),
      rows: rows.length,

      // 6. the composer is reachable — a card that clips it is worse than no card
      composerInPanel: box(form).bottom <= box(panel).bottom + 1,
      lastRowRule: rows.length ? parseFloat(cs(rows[rows.length - 1]).borderBottomWidth) : -1,
    };
  });

  ok("the transcript carries the sky", m.logHasSky === true);
  /* THE PANEL MUST NOT, and this is the arm that fails if somebody moves the
     plate back up one level to get the head and composer tinted by it again. */
  ok("...and the panel itself does not", m.panelHasSky === false);
  ok("no sky behind the warning", m.skyBehindHead === false);
  ok("no sky behind the composer", m.skyBehindForm === false);
  ok("no stars behind the box you type into", m.skyBehindInput === false);
  ok("no sky behind the note", m.skyBehindNote === false);
  /* WHICH ONLY HOLDS IF THE PANEL IS OPAQUE. The bands are transparent by
     design — this file inherits its colours and must not grow a copy of the
     page's tokens — so the panel's own base is the surface they are painted on,
     and a translucent base puts the page's sky back behind all of them. */
  ok("the panel's base is opaque, which is what the bands are painted on",
     m.panelOpaque === true);

  /* NO GAP EITHER SIDE OF THE LOG. Margins here were the other half of the
     defect: .chatform had margin-top and .chathead margin-bottom, so between two
     bands there was a strip of whatever the panel was painted with. */
  ok("the head meets the log", m.headToLog === 0);
  ok("the log's edge meets what is under it", m.logToNext === 0);
  ok("...and every band in the column tiles", m.worstSeam === 0);

  ok("a rule states where the scroll starts", m.headRule >= 1);
  ok("...and where it ends", m.logRule >= 1);

  ok("the room has edges all round", m.panelBorder >= 1 && m.panelRadius >= 4);
  /* AND NO LEFTOVER OFFSET. padding-top on the panel was the visible half of
     "strange how the chat has padding around it": a rule across the top, space
     under it, and no edge anywhere else for either to belong to. */
  ok("...and no stray padding outside them", m.panelPadTop === 0);

  ok("the notice, the messages and the composer share one left edge",
     m.rows > 0 && m.warnLeft === m.rowLeft && m.rowLeft === m.inputBandLeft);

  ok("the composer is inside the card", m.composerInPanel === true);
  ok("the last row drops its hairline so the log's edge is one line",
     m.lastRowRule === 0);

  /* AND THE ONE BAND THAT IS NOT ON SCREEN TO BE MEASURED.
     .chatstate is the panel's own status pill — hidden until the panel has
     something to say — so the tiling arm above cannot see it, and mutation
     testing proved the point: restoring its margin-top was the ONE change to
     this stylesheet that every other arm here let through. A band that is
     invisible in the fixture is a band with no test, so the fixture shows it.
     WRITING TO IT IS WHAT THE PANEL DOES. The server's error and rate-limit
     notices land here; this sets the same two things mountChat sets and then
     asks the same question of the geometry. */
  const stateSeam = await page.evaluate(() => {
    const st = document.querySelector("#chatview .chatstate");
    if (!st) return null;
    st.removeAttribute("hidden");
    st.textContent = "something the panel had to say";
    const panel = document.getElementById("chatview");
    const box = e => e.getBoundingClientRect();
    const vis = [...panel.children].filter(e => box(e).height > 0);
    if (!vis.includes(st)) return null;
    let worst = 0;
    for (let i = 1; i < vis.length; i++) {
      const g = Math.abs(box(vis[i]).top - box(vis[i - 1]).bottom);
      if (g > worst) worst = g;
    }
    return {shown: true, worstSeam: Math.round(worst)};
  });
  ok("the status pill shows when told to", stateSeam && stateSeam.shown === true);
  ok("...and it tiles with the bands around it too",
     !!stateSeam && stateSeam.worstSeam === 0);

  ok("no page errors", errors.length === 0);

  await browser.close();
  console.log(JSON.stringify(m));
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
