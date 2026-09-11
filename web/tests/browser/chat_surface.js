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
    /* A SKY IS A SKY WHATEVER IT IS DELIVERED AS. This tested for "base64" alone,
       which described the rail's inline plate and nothing else -- so when the
       panel's sky became a file, sky.svg, every arm below went on answering about
       a plate that was no longer there. Four of them PASSED while the property
       they guard had inverted, which is the failure mode a proxy has and a direct
       question does not. */
    const plated = e => /base64|sky\.svg/.test(cs(e).backgroundImage);
    const box = e => e.getBoundingClientRect();
    const panel = document.getElementById("chatview");

    /* THE WALK IS THE TEST, AND IT RUNS ALL THE WAY UP.
       It used to stop at the panel, paired with a second arm asserting the
       panel's own base was opaque; together those two said "and nothing above it
       can show through either". That pairing broke as soon as the base became
       rgba(255,255,255,.1) — and it broke in the direction that matters, with
       the PROXY failing while the thing it stood for was still true.
       A TRANSLUCENT PANEL IS NOT THE DEFECT. The defect was a starfield behind
       the box you type into; whether the panel lets the page show through is a
       different question from whether what shows through is sky. So the walk no
       longer stops, and no longer cares what any alpha along it happens to be:
       it asks the only question worth asking, from the band to the document, and
       gives the same answer however the panel is tinted. */
    const skyBehind = el => {
      for (let n = el; n; n = n.parentElement) if (plated(n)) return true;
      return false;
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
      /* AND WHETHER THE FIELD STOPS IT. Once the sky is on the panel, "is there
         sky behind this" is true of everything in the panel and can no longer
         tell the field apart -- so the question becomes whether the field paints
         a ground of its own opaque enough to hide what is under it. That is the
         property the original arm was really guarding. */
      inputOwnAlpha: (() => {
        const c = cs(input).backgroundColor;
        const m = c.match(/rgba?\(([^)]+)\)/);
        if (!m) return 0;
        const p = m[1].split(",").map(Number);
        return p.length < 4 ? 1 : p[3];
      })(),
      skyBehindNote: skyBehind(note),

      /* 2. THE BANDS MEET THE LOG WITH NO SEAM EITHER SIDE OF IT.
         Not log-to-form: .chatstate and .chathere sit between them, and the
         first cut asserted log.top === form.top and failed by 22px on a room
         that was correct — .chathere was in the gap saying "3 here". So the arm
         is the log's edge against whatever is actually next to it, which is
         what the two hairlines are drawn on. */
      headToLog: Math.round(box(log).top - box(head).bottom),
      logToNext: (() => {
        const inFlow = e => {
          const pos = getComputedStyle(e).position;
          return pos !== "absolute" && pos !== "fixed";
        };
        const vis = [...panel.children].filter(e => box(e).height > 0 && inFlow(e));
        const i = vis.indexOf(log);
        return i >= 0 && i + 1 < vis.length
          ? Math.round(box(vis[i + 1]).top - box(log).bottom) : null;
      })(),
      /* AND THE WHOLE COLUMN TILES: every visible band starts where the one
         above it ended. One number for the worst seam in the panel, so a margin
         reintroduced anywhere in the stack shows up here rather than in whichever
         single pair the arms happened to name. */
      worstSeam: (() => {
        const inFlow = e => {
          const pos = getComputedStyle(e).position;
          return pos !== "absolute" && pos !== "fixed";
        };
        const vis = [...panel.children].filter(e => box(e).height > 0 && inFlow(e));
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

  /* THE SKY IS ON THE PANEL NOW, AND THAT IS THE REQUEST, NOT A REGRESSION.
     These arms used to say the opposite -- sky on the log, none on the panel, and
     specifically none behind the box you type into. That was the right shape
     while the panel needed an opaque base; it was asked to change, in these
     words: "i can't see any space background from the top or bottom of the
     chat". The picture had no way to reach the head and the composer while it was
     painted on the one row between them. So it moved up a level, the log went
     transparent, and one continuous sky runs from the notice to the composer.
     WHAT PROTECTS THE TEXT IS NO LONGER ITS ABSENCE. The head, the composer and
     the note carry a scrim of their own -- rgba(22,18,46,.45), the rail's surface
     colour -- and the sky behind them is under a veil that caps it well below the
     ink. Those are the arms below; the two that follow here only fix where the
     picture lives. */
  ok("the panel carries the sky", m.panelHasSky === true);
  ok("...and the log does not paint a second one", m.logHasSky === false);
  ok("the sky reaches the warning", m.skyBehindHead === true);
  ok("...and the composer", m.skyBehindForm === true);
  ok("...and the note", m.skyBehindNote === true);
  /* AND STILL NOT INSIDE THE FIELD ITSELF. The input keeps its own background, so
     what you are typing is never read against a starfield -- which was the actual
     complaint behind the original arm, and survives the inversion above. */
  ok(`but the box you type into paints its own ground (alpha ${m.inputOwnAlpha})`,
     m.inputOwnAlpha >= 0.6, JSON.stringify({inputOwnAlpha: m.inputOwnAlpha}));
  /* AND THE ARM THAT USED TO SIT HERE IS GONE ON PURPOSE. It read "the panel's
     base is opaque, which is what the bands are painted on" — true when written
     and false a day later, when the base became a tenth of white so the chat's
     background would read grey rather than black. Nothing about the reported
     defect changed; only the proxy did. The walk above now covers what this was
     standing in for, at every alpha, so there is nothing left for it to say. */

  /* NO GAP EITHER SIDE OF THE LOG. Margins here were the other half of the
     defect: .chatform had margin-top and .chathead margin-bottom, so between two
     bands there was a strip of whatever the panel was painted with. */
  ok("the head meets the log", m.headToLog === 0);
  ok("the log's edge meets what is under it", m.logToNext === 0);
  ok("...and every band in the column tiles", m.worstSeam === 0);

  ok("a rule states where the scroll starts", m.headRule >= 1);
  /* AND NOTHING STATES WHERE IT ENDS, WHICH IS DELIBERATE. The log carried a
     border-bottom so the scrolling region was ruled at both ends; it was reported
     as "just above the chat field there is a horizontal line between that and
     chat text. remove it" and taken out. The head's rule stays -- the arm above
     -- because the top of the scroll still wants stating, and the composer's own
     edge states the bottom well enough. Asserting the rule back would be
     asserting a design that was rejected. */
  ok("...and nothing rules its foot, which was asked for", m.logRule === 0,
     `logRule=${m.logRule}`);

  /* NO CARD. This asked for a 1px border and a >=4px radius on the reasoning that
     "the room has edges all round". It has no edges now, on purpose: the panel
     bleeds past main's gutters to both window edges, where a rounded corner has
     nothing to be a corner of, and the frame was removed in those words --
     "remove the rounded borders around the chat box". What still matters is that
     it not go halfway, carrying one and not the other. */
  ok("the room has no card frame, which was asked for",
     m.panelBorder === 0 && m.panelRadius === 0,
     `border=${m.panelBorder} radius=${m.panelRadius}`);
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
    // Same exclusion as the walk above, and for the same reason: the count is
    // position:absolute and tiles with nothing.
    const inFlow = e => {
      const pos = getComputedStyle(e).position;
      return pos !== "absolute" && pos !== "fixed";
    };
    const vis = [...panel.children].filter(e => box(e).height > 0 && inFlow(e));
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
      // the gutter the room bleeds through, read from main rather than hardcoded:
      // it is a clamp(), so it is 44px here and something else on another window.
      gutter: mc.paddingRight,
    };
  });
  ok("main is told it is holding a room", fill.roomfill === true);
  ok("the room is not capped narrower than the page", fill.cap === "none");
  const bleed = Math.round(parseFloat(fill.gutter));
  ok(`...so its right edge clears the measure by the gutter (${fill.gapRight} vs ${-bleed})`,
     fill.gapRight === -bleed, JSON.stringify(fill));
  ok(`...and its left edge by the same (${fill.gapLeft})`,
     fill.gapLeft === fill.gapRight, JSON.stringify(fill));
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
