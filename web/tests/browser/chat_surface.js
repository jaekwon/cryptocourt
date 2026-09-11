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
/* THE THIRD ARGUMENT IS THE MEASUREMENT, and leaving it out cost a debugging
   round: every arm below already passed one, this helper took two parameters and
   silently dropped it, so a failing geometry arm printed its name and nothing
   about the geometry. Printed only on failure — a passing run says "ok" and
   stays readable. */
const ok = (n, c, d) => {
  if (!c) { fail++; console.log("FAIL:", n, d === undefined ? "" : d); }
  else console.log("ok:", n);
};

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
    /* AND PUT IT BACK, which is the whole reason this is its own paragraph.
       Showing the pill adds ~40px of content to a panel that is sized by the
       space left over, so the page it leaves behind scrolls by 5px and sits 19px
       off its foot — and the fill arms below, measured on that page, failed on a
       layout that was correct. A fixture mutated for one arm and left dirty for
       the next is a test reporting its own damage as a defect. */
    st.setAttribute("hidden", "");
    st.textContent = "";
    return {shown: true, worstSeam: Math.round(worst)};
  });
  ok("the status pill shows when told to", stateSeam && stateSeam.shown === true);
  ok("...and it tiles with the bands around it too",
     !!stateSeam && stateSeam.worstSeam === 0);

  /* ---------------------------------------------------------------------------
     AND THE ROOM TAKES THE SPACE IT IS GIVEN.
     REPORTED AS "you know all that space around the chat box? in the background
     color... get rid of it" — a 760px card in a 968px measure, so 208px of page
     background to its right, and 74px of nothing under it on a 900px window.
     THE ARMS ARE THE EDGES, NOT THE NUMBERS. Asserting "968px wide" would pin
     the viewport this harness happens to use; asserting that the panel's right
     edge IS the measure's right edge is the same claim at every width, and it is
     the claim the reader made. Same below: the gap under the room is the page's
     foot and nothing more. */
  const fill = await page.evaluate(() => {
    const main = document.getElementById("main"), cv = document.getElementById("chatview");
    const cs = e => getComputedStyle(e), bx = e => e.getBoundingClientRect();
    const mb = bx(main), cb = bx(cv), mc = cs(main);
    const form = cv.querySelector(".chatform");
    return {
      roomfill: main.classList.contains("roomfill"),
      cap: cs(cv).maxWidth,
      // the measure's own right edge, which is main minus its gutter
      gapRight: Math.round((mb.right - parseFloat(mc.paddingRight)) - cb.right),
      gapLeft: Math.round(cb.left - (mb.left + parseFloat(mc.paddingLeft))),
      /* AGAINST main's BOTTOM, NOT THE WINDOW'S. Measuring the gap to the
         viewport made this arm a question about the RAIL: the rail is the
         tallest thing on the page, both grid items stretch to the taller, and in
         this fixture it comes out 905px on a 900px window — so the page scrolls
         5px, the room's bottom sits 19px off the fold instead of 24, and two
         arms failed on a layout that measured exactly right when checked on its
         own. The room reaching the page's foot is the claim; whether the RAIL
         overflows the window is not this file's business. */
      gapBelow: Math.round(mb.bottom - cb.bottom),
      foot: Math.round(parseFloat(mc.paddingBottom)),
      railOverflow: Math.round(bx(document.querySelector(".rail")).height
        - document.documentElement.clientHeight),
      composerOnScreen: bx(form).bottom <= document.documentElement.clientHeight + 1,
    };
  });
  ok("main is told it is holding a room", fill.roomfill === true);
  ok("the room is not capped narrower than the page", fill.cap === "none");
  ok("...so its right edge is the measure's right edge", fill.gapRight === 0,
     JSON.stringify(fill));
  ok("...and its left edge is too", fill.gapLeft === 0, JSON.stringify(fill));
  /* THE GAP BELOW IS THE FOOT, WHICH IS NOT THE SAME AS "SMALL". main's foot is
     90px for an article that ends and 24 for a room whose bottom edge is the
     composer; tying the arm to the computed padding rather than to 24 means the
     foot can be retuned without editing a test, and a foot that grows back to 90
     still fails because the room would no longer reach it. */
  ok(`the room reaches the page's foot and no further (${fill.gapBelow}px / ${fill.foot}px)`,
     fill.gapBelow === fill.foot, JSON.stringify(fill));
  /* AND THE FOOT IS SMALL, WHICH THE ARM ABOVE CANNOT SEE. Reading the foot from
     the computed padding was meant to let it be retuned without editing a test;
     what it actually bought was a tautology — restore the page's 90px foot and
     `gapBelow === foot` is still true, with 90px of background under the room,
     which is most of what was complained about. MUTATION TESTING FOUND THIS: it
     was the one revert of the ten that nothing caught.
     32 rather than 24 so the value can move a little; 90 is the number being
     excluded, and the court page's own foot is asserted to still be above 24
     further down, so the two together pin that the room's foot DIFFERS from an
     article's rather than just happening to be some number. */
  ok(`...and that foot is a margin, not an article's ending (${fill.foot}px)`,
     fill.foot <= 32, JSON.stringify(fill));
  /* AND THE COMPOSER IS ON SCREEN, which is the arm that would catch the room
     overshooting the window even though the one above it cannot: a panel handed
     more than the window has satisfies "reaches main's foot" perfectly while
     hanging off the bottom, because main went with it. This is only sound while
     the rail is not itself taller than the window, hence the note. */
  ok(`...with the composer on screen without scrolling`
     + (fill.railOverflow > 0 ? ` (the rail overflows by ${fill.railOverflow}px)` : ""),
     fill.composerOnScreen === true, JSON.stringify(fill));

  /* AND THE CLASS IS RELEASED ON THE WAY OUT. It is only ever ADDED by one route,
     which is exactly the shape that leaves the NEXT page a flex column with a
     24px foot — the bug lives on a different view than the code that causes it,
     so it is measured on a different view than the code that causes it. */
  await page.evaluate(() => { location.hash = "#/c/orem"; });
  await page.waitForFunction(() => !document.getElementById("chatview"), {timeout: 20000});
  await new Promise(r => setTimeout(r, 500));
  const after = await page.evaluate(() => {
    const main = document.getElementById("main");
    return {roomfill: main.classList.contains("roomfill"),
            display: getComputedStyle(main).display,
            foot: Math.round(parseFloat(getComputedStyle(main).paddingBottom))};
  });
  ok("leaving the room releases the layout", after.roomfill === false,
     JSON.stringify(after));
  ok("...so the court page is a block again, with its own foot",
     after.display === "block" && after.foot > 24, JSON.stringify(after));

  ok("no page errors", errors.length === 0);

  await browser.close();
  console.log(JSON.stringify(m));
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
