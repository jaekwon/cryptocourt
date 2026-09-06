#!/usr/bin/env node
// The one claim figure, and the fence around it.
//
// WHAT MAKES THIS DIFFERENT FROM EVERY OTHER SECTION ON THE CLAIM PAGE: the
// title, the body, the exhibits, the stake and the verdict are read off the
// chain. This is written here. It is an illustration of what a claim already
// says, and that makes it editorial in a viewer that is otherwise a window.
//
// So the tests are mostly about the FENCE — that it is one registry with one
// entry, that it fires for exactly one claim and for nothing else, and that it
// cannot put chain text into the DOM as markup.
const { src, fn } = require("./srcslice");

let fail = 0;
const ok = (n, c, d) => { if (!c) { fail++; console.log("FAIL:", n, d || ""); } else console.log("ok:", n); };

const reg  = src.slice(src.indexOf("const CLAIM_FIGURES"), src.indexOf("function fillClaimFigure"));
const fill = fn("fillClaimFigure");
const fig  = fn("cherryFigure");

/* ONE ENTRY. The value of a registry with a single key is that a second one has
   to be added HERE, beside the first, where the question "should either of these
   exist" gets asked. A figure mounted from inside a page section would not. */
const keys = [...reg.matchAll(/"([a-z0-9-]+\/\d+)"\s*:/g)].map(m => m[1]);
ok("the registry holds exactly one claim", keys.length === 1, JSON.stringify(keys));
ok("...and it is covid/12, the claim that argues about the denominator",
   keys[0] === "covid/12");

/* IT FIRES FOR THAT CLAIM AND NO OTHER. The lookup is the whole gate: a miss
   returns before anything is built, so every other claim on every chain — and
   every claim numbered 12 in a different court — renders exactly as before. */
ok("the gate is a lookup on court AND id, not on id alone",
   /CLAIM_FIGURES\[\s*slug\s*\+\s*"\/"\s*\+\s*id\s*\]/.test(fill));
ok("a claim with no figure returns before building anything",
   /if\(!fig\)\s*return;/.test(fill));
ok("a throwing figure leaves the page whole rather than half-drawn",
   /try\s*\{\s*fig\(host\);\s*\}\s*catch/.test(fill));
ok("...and there is a host for it on the claim page", /id="claimfig"/.test(src));
ok("...mounted with the other fills", /fillClaimFigure\(slug, id\);/.test(src));

/* NOTHING FROM THE CHAIN REACHES THIS DOM AS MARKUP. The figure's own strings
   are the only ones it prints, and they are set with textContent — so the day
   somebody wires a claim title into the caption, the shape of the code already
   refuses it. innerHTML appears twice on purpose and both are constant markup
   with no interpolation of anything read. */
ok("the running commentary is set as text, never as markup",
   /say\.textContent\s*=/.test(fig) && !/say\.innerHTML/.test(fig));
ok("the caption and the key are text too",
   /sub\.textContent\s*=/.test(fig) && /key\.textContent\s*=/.test(fig));
const interpolatedHTML = /innerHTML\s*=\s*`[^`]*\$\{/.test(fig);
ok("no innerHTML carries an interpolated value", !interpolatedHTML);

/* THE ARITHMETIC IS THE POINT, so the counts have to land on the figure the
   claim is arguing about. 14/17 is 82%; if somebody retunes the tree and forgets
   the copy, the section explains a number it no longer shows. */
const N = /const N = \{loss:(\d+), birth:(\d+), ongoing:(\d+)\}/.exec(fig);
ok("the tree declares its counts", !!N);
if (N) {
  const [loss, birth, ongoing] = N.slice(1).map(Number);
  ok("100 pregnancies", loss + birth + ongoing === 100, `${loss}+${birth}+${ongoing}`);
  ok("...and the ripe ones divide to the number in the copy",
     Math.round(loss / (loss + birth) * 100) === 82, `${loss}/${loss + birth}`);
  ok("...which is the number the commentary names",
     /That is the 82%\./.test(fig));
  ok("most of the tree is still ongoing, or the point does not land",
     ongoing > 3 * (loss + birth), String(ongoing));
}

/* AN ONGOING PREGNANCY CANNOT BE PICKED, which is the argument itself: it has no
   outcome yet, so there is no fruit. If it were clickable the figure would say
   the denominator was a choice among equals, and it is not. */
ok("only a ripe cherry gets a click handler", /if\(ripe\)\{[\s\S]{0,200}addEventListener\("click"/.test(fig));
ok("...and an ongoing one is marked as not a control",
   /role:\s*ripe\?"button":"img"/.test(fig) && /tabindex:\s*ripe\?"0":"-1"/.test(fig));

/* THE SCATTER IS FIXED. Math.random would redraw the tree on every visit, so two
   readers comparing what they saw would be comparing two trees. */
/* The CALL, not the word: the figure's own comment explains why Math.random is
   not used, and a bare-word scan reads that explanation as the thing it forbids.
   That happened here on the first run — the same shape as a sample btn() inside
   a comment being counted as a real button. */
ok("the tree is the same tree every time", !/Math\.random\(/.test(fig) && /seed = 7/.test(fig));
ok("...and the layout loop cannot spin for ever", /guard\+\+ < \d+/.test(fig));

/* SCALE IS ABOUT THE ORIGIN. translate(bx-x, by-y) scale(s) lands each fruit at
   bx-(1-s)x — an offset that varies with where it hung, which drew the basket as
   a diagonal spray. The scaled point has to be subtracted. Pinned because the
   wrong version LOOKS deliberate. */
ok("a picked cherry is placed with the scale accounted for",
   /translate\(\$\{\(bx - S\*c\.x\)/.test(fig) && /scale\(\$\{S\}\)/.test(fig));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
