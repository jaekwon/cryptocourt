// The Resolution panel takes the verdict's side, in paint.
//
// WHY THIS EXISTS. The panel announced BOTH outcomes as `notice good` with a ✓ —
// so a claim the court ruled FALSE arrived in the winning side's green under a
// tick, directly beneath a heading that had just been changed to strike the same
// sentence through and ring it in --no. It is the largest, most declarative
// element on the claim route, and it was the last one still saying yes.
//
// WHY IN A BROWSER, and not in a source harness. What went wrong was a COLOUR,
// and the source has no colours in it: the branch emits a class name, and
// whether that class resolves to green, to red, or to nothing at all is a fact
// about the stylesheet and the active theme. A source check reading
// `notice ruled-no` in the template would pass against a `.ruled-no` rule that
// was never written, or one whose --no-wash is undefined in the light theme —
// both of which put a WHITE panel on the page and both of which look exactly
// like the bug this file is here about. So every hue below is read back from the
// laid-out element with getComputedStyle, and compared against the token the
// page itself resolves rather than a hex copied into this file: a literal here
// would keep passing after somebody changes --no.
//
// RENDERED FROM A FIXTURE, for the same reason map_draws.js renders one — the
// demo court's only settled claim is a YES, so no settled-NO panel exists on any
// route this check could navigate to, and the CSS for it would ship unexercised.
// The fixture goes inside #main so the page's own cascade applies to it exactly
// as it does to the real one.
//
// ABLATED, four ways, against a CONTROL run of the unmodified copy that fires
// nothing — without it "3 arms fired" is not evidence, since a copy that fails
// for its own reasons would report the same. Counts are what actually fired, in
// the dark theme; two of them are higher than the first version of this comment
// predicted, and the guesses are corrected here rather than rounded off:
//   - class back to `notice good` for both  -> 3: not-green, wash, and --no
//     exactly. That is the shipped bug reproduced, and it is the only ablation
//     that trips the not-green arm. The glyph arm passes, as predicted.
//   - glyph back to ✓ for both              -> 1: the glyph arm alone.
//   - delete the .notice.ruled-no rule      -> 3: wash (transparent, not green),
//     --no exactly (the inherited page ink), and the 4px stripe (0px). The
//     not-green arm PASSES here, which is the discrimination this file is built
//     for: a missing rule and a green rule are different failures, and asserting
//     the resolved token rather than "not green" is what separates them.
//   - swap ruled-no's var(--no) for var(--contra) -> 1: the --no-exactly arm
//     alone. --contra is the adjacent red in this palette, and an assertion
//     phrased as "reddish" would have let it through.
// The mutations run against a COPY of index.html outside the repo, because a
// second session edits the shared file: an earlier pass mutated it in place,
// died before restoring, and had the mutation written back from that session's
// stale buffer after it was repaired. An isolated copy has no such window.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1200, height: 900});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  await page.goto(PAGE + '#/', {waitUntil: 'domcontentloaded'});
  await new Promise(r => setTimeout(r, 800));

  const read = await page.evaluate(() => {
    try {
      // The tokens as THIS page resolves them, in the theme it is actually in.
      const probe = t => { const p = document.createElement('span');
        p.style.color = "var(" + t + ")"; document.body.appendChild(p);
        const c = getComputedStyle(p).color; p.remove(); return c; };
      const bgOf = t => { const p = document.createElement('span');
        p.style.background = "var(" + t + ")"; document.body.appendChild(p);
        const c = getComputedStyle(p).backgroundColor; p.remove(); return c; };

      const host = document.createElement('div');
      document.getElementById('main').appendChild(host);
      const panel = side => {
        // verdict 0 is YES, 1 is NO — the realm's own encoding, which sideName reads.
        const d = {phase: "settled", verdict: side, answer: side, route: "vote",
                   rewardsOpened: false, draw: null};
        host.innerHTML = resolutionSection("covid", 1, d, 100, null);
        const n = host.querySelector('.notice');
        if (!n) return null;
        const cs = getComputedStyle(n);
        return {cls: n.getAttribute('class'), bg: cs.backgroundColor,
                border: cs.borderLeftColor, w: cs.borderLeftWidth,
                glyph: (n.querySelector('.g') || {}).textContent,
                text: (n.textContent || "").slice(0, 40)};
      };
      const yes = panel(0), no = panel(1);
      host.remove();
      return {yes, no, tYes: probe("--yes"), tNo: probe("--no"),
              tContra: probe("--contra"),
              wYes: bgOf("--yes-wash"), wNo: bgOf("--no-wash")};
    } catch (e) { return {err: String(e).slice(0, 200)}; }
  });

  ok("both settled panels render", !!(read.yes && read.no), read.err || JSON.stringify(read).slice(0, 200));
  if (read.yes && read.no) {
    // The fixture really is producing the two verdicts, or everything below is
    // measuring one panel twice.
    ok("the fixture produces a YES panel and a NO panel",
       /Settled YES/.test(read.yes.text) && /Settled NO/.test(read.no.text),
       `"${read.yes.text}" | "${read.no.text}"`);

    ok("a settled YES keeps the winning side's wash",
       read.yes.bg === read.wYes, `${read.yes.bg} vs --yes-wash ${read.wYes}`);
    ok("...under the winning side's rule",
       read.yes.border === read.tYes, `${read.yes.border} vs --yes ${read.tYes}`);
    ok("...with the tick",
       read.yes.glyph === "✓", JSON.stringify(read.yes.glyph));

    // THE ASSERTION THIS FILE IS FOR.
    ok("a settled NO is NOT painted in the winning side's green",
       read.no.bg !== read.wYes && read.no.border !== read.tYes,
       `bg=${read.no.bg} border=${read.no.border} (green is ${read.wYes} / ${read.tYes})`);
    ok("...it takes the losing side's wash",
       read.no.bg === read.wNo, `${read.no.bg} vs --no-wash ${read.wNo}`);
    ok("...and --no exactly, not the adjacent red",
       read.no.border === read.tNo && read.no.border !== read.tContra,
       `${read.no.border} vs --no ${read.tNo}, --contra ${read.tContra}`);
    ok("...and does not wear the tick",
       read.no.glyph === "✕", JSON.stringify(read.no.glyph));

    // The stripe is what makes either read as a verdict rather than as body
    // text; a rule that resolves but sets no border-left-width is still a miss.
    ok("both keep the 4px side stripe",
       parseFloat(read.yes.w) >= 4 && parseFloat(read.no.w) >= 4,
       `${read.yes.w} / ${read.no.w}`);

    /* AND IT IS NOT THE ERROR CLASS. .notice.refuse carries the same wash and
       means the SITE failed — "Not JSON", "Rejected, nothing was applied". A
       court ruling NO is a complete and successful outcome, so the two are kept
       as separate rules that happen to agree today; reusing refuse here is the
       shortcut this asserts against, because it would make any future restyle of
       the error state silently restyle a verdict. */
    ok("a verdict does not borrow the site's error class",
       !/\brefuse\b/.test(read.no.cls), read.no.cls);
  }

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
