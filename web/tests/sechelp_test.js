#!/usr/bin/env node
// The `?` beside a section heading — what it is allowed to be made of.
//
// WHY THIS EXISTS. "Open docket" is the courthouse word and it is the right one:
// a docket is the list of cases before a court, and the whole product is built
// on that metaphor. But a reader who does not already have the word got no way
// to ask, and the answer is one sentence — too little for the helper DIALOG that
// "How this vote works" opens, too much for the heading itself. So the heading
// grew a `?`.
//
// AND THE `?` IS THE PART THAT NEEDED PINNING, because every wrong version of it
// looks right on the machine that built it:
//
//   title="…"      is what the page's OTHER `?` uses — .vq, on the claim heading.
//                  No keyboard reaches it and no touch screen shows it. It looks
//                  perfect to a person with a mouse, which is the person writing
//                  it.
//   :focus-visible reveals on Tab but NOT on tap: a touch focus does not match
//                  it. Shipped that way for one round here — the browser check
//                  caught it because programmatic focus does not match
//                  focus-visible either, which is the accident that made a
//                  touch-only bug visible from a script.
//   aria on both   the button naming the sentence AND the panel exposing it says
//                  the same sentence to a screen reader twice.
//
// None of the three changes a pixel. All three are source-visible, which is what
// this file is for. The behaviours themselves — hover opens, Tab opens, tap
// opens, pointer-out closes — are measured in a browser against the real court
// page, since a stylesheet assertion cannot prove a panel appeared.
const { src, fn } = require("./srcslice");
let fail = 0;
const ok = (n, c, extra) => { if (!c) { fail++; console.log("FAIL:", n, extra === undefined ? "" : extra); } else console.log("ok:", n); };

global.esc = s => String(s).replace(/[&<>"'`]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;", "`": "&#96;"}[c]));
eval(fn("secHelp"));

const out = secHelp("A docket is the list of cases before a court.");

// ---- it is a control, not an attribute ------------------------------------
ok("it is a real button", /^<button type="button" class="sq"/.test(out), out);
/* THE WHOLE POINT, STATED AS A PROHIBITION. A title= would pass every other
   assertion in this file and fail every user who is not holding a mouse. */
ok("...and carries no title attribute", !/title=/.test(out), out);
ok("...so it is in the tab order by construction", !/tabindex/.test(out), out);

// ---- said once, to each audience ------------------------------------------
ok("the sentence is the button's own accessible name",
   out.includes('aria-label="A docket is the list of cases before a court."'), out);
/* The panel repeats the sentence for an EYE. Without aria-hidden a screen reader
   reads the label and then the panel — the same sentence, twice, and the second
   time with no way to tell it is the same. */
ok("...and the panel that repeats it is hidden from assistive tech",
   /<span class="sqp" aria-hidden="true">/.test(out), out);
ok("...with no id to thread, so a template without an id scheme can use it",
   !/aria-describedby|id=/.test(out), out);

// ---- untrusted text ---------------------------------------------------------
/* Today every caller passes a literal. The escaping is asserted anyway: the next
   caller passes a folder name or a court's own description, and that is the
   round where nobody re-reads this function. */
/* ASSERTED AS THE TAG SET, not as absent bad words — the same mistake made once
   already in rawmd_test. Correct ESCAPED output contains the string
   `onmouseover=&quot;`, so a grep for `onmouseover=` fails on working code and
   invites someone to loosen the check. What matters is whether any of it is
   MARKUP, and secHelp is made of exactly two tags. */
{
  const bad = secHelp('</span><script>alert(1)</script>" onmouseover="x');
  const tags = [...new Set((bad.match(/<\/?([a-z0-9]+)/g) || []).map(t => t.replace(/[<\/]/g, "")))].sort();
  ok("the payload opens no tag of its own", tags.join(",") === "button,span", tags.join(","));
  /* Escaped is not deleted: the sentence still has to reach the reader. */
  ok("...and survives, escaped, in both places it appears",
     (bad.match(/&lt;script&gt;/g) || []).length === 2 && bad.includes("&quot;"), bad.slice(0, 140));
  /* The label is an ATTRIBUTE, so the quote that would break out of it is the
     character that matters most there. */
  ok("...with no quote able to break out of aria-label",
     /aria-label="[^"]*"/.test(bad) && !/aria-label="[^"]*"\s+[a-z-]+=/.test(bad.replace(/(<span)/, "\n$1")), bad.slice(0, 160));
}

// ---- the stylesheet, which is where the touch bug lived --------------------
const css = src.slice(src.indexOf(".sq{"), src.indexOf(".sq{") + 1600);
ok("the panel is hidden at rest by visibility, not by opacity alone",
   /\.sqp\{[^}]*visibility:hidden/.test(css), css.slice(0, 200));
/* :focus, NOT :focus-visible — a tap focuses without matching focus-visible, so
   the panel would never open on a phone and the `?` would be a button that does
   nothing. Asserted as an exclusion because the wrong version is one word longer
   than the right one and reads more correct. */
ok("hover OR focus reveals it", /\.sq:hover \.sqp,\.sq:focus \.sqp\{[^}]*visibility:visible/.test(css), css);
ok("...and not focus-visible, which a tap does not match",
   !/:focus-visible \.sqp/.test(css), css);
/* .sec-h is uppercase with .14em tracking. A sentence inherited into that is a
   sign, not a sentence. */
ok("the panel resets the heading's uppercase and tracking",
   /\.sqp\{[^}]*text-transform:none/.test(css) && /\.sqp\{[^}]*letter-spacing:0/.test(css), css.slice(0, 400));
ok("...and is bounded so it cannot run off a narrow screen",
   /\.sqp\{[^}]*max-width:min\(/.test(css), css.slice(0, 400));
/* ANCHORED TO THE HEADING, NOT TO THE BUTTON — the bug that shipped. The panel
   was positioned against the 15px circle, which sits partway along the heading,
   so "left:0" meant the left edge of THAT: ~127px in, plus a 273px panel, on a
   390px viewport. The page scrolled sideways. WCAG 1.4.10.
   Asserted as the three facts that together bound it — the button is NOT the
   containing block, the heading IS, and the width is a share of that container
   rather than of the viewport. A vw max-width is what let a panel be wider than
   the column it hangs off. */
ok("the button is not the panel's containing block", /\.sq\{position:static/.test(src));
ok("...the heading is", /\.sec-h\{position:relative\}/.test(src));
ok("...and the panel is bounded by that container, not by the viewport",
   /\.sqp\{[^}]*max-width:min\(320px,100%\)/.test(css) && !/\.sqp\{[^}]*vw/.test(css), css.slice(0, 300));
ok("...and the fade is dropped for reduced motion",
   /prefers-reduced-motion:reduce\)\{ \.sqp\{transition:none/.test(src));

// ---- the one caller today ---------------------------------------------------
/* The heading is "Open" now, not "Open docket", so the sentence no longer opens
   by defining a word the reader can no longer see. What it must still do is say
   what the section holds and where the rest of the claims went. */
ok("Open is the heading that carries it",
   /<div class="sec-h">Open \$\{secHelp\("Claims this court has not settled yet/.test(src));
ok("...and it defines no word the heading stopped using",
   !/secHelp\("A docket is/.test(src));
ok("...and the sentence says what the section holds AND where the rest went",
   /not settled yet[\s\S]{0,80}Recently settled/.test(src));
/* The pair it names has to exist, or the sentence sends a reader somewhere the
   page does not have. */
ok("...and Recently settled is really the section below it",
   src.includes('<div class="sec-h">Recently settled'));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
