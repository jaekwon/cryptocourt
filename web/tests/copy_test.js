#!/usr/bin/env node
// Words the product does not say out loud.
//
// WHY THIS EXISTS. "open the rewards" is the realm's word for opening a claim's
// reward draw. It is a fine name for an entrypoint and a bad one for a reader:
// it appears on no button, in no heading and in no hint — the control says "Open
// the rewards" — and it reached the screen anyway, because the sent-toast printed
// the raw function name the tx had called. Pressing "Open the rewards" answered
// "Sent. OpenRewards is on its way."
//
// THE NAME IS NOT RENAMED, and that is the distinction this file draws. The
// realm's entrypoint is OpenRewards, the tx has to call it, and RewardsOpened() is
// the read that answers whether the draw is open. What is banned is the word in
// COPY — anything a reader is shown. So the scan below looks at string literals
// and allows exactly the shapes that are API surface.
//
// Ablated: putting the word back in the toast, in a hint, or in the realm's
// rendered line each fails the arm named for it; and removing OpenRewards from
// TX_SENT fails the mapping arm rather than the scan, since the scan cannot see
// what an unmapped fallback would print.
const fs = require('fs');
const path = require('path');
const { src } = require("./srcslice");
const render = fs.readFileSync(
  path.join(__dirname, '..', '..', 'realm', 'r', 'kourtv2', 'render.gno'), 'utf8');
let fail = 0;
const ok = (n, c, d) => { if (!c) { fail++; console.log("FAIL:", n, d || ""); } else console.log("ok:", n); };

/* THE API SHAPES, spelled out rather than pattern-matched loosely: the entrypoint
   a button posts to, the read that answers whether the draw is open, and the
   argument form of each. Anything else carrying the word is copy. */
const API = [
  /^OpenRewards$/,                    // btn(..., "OpenRewards", ...) — the tx name
  /^RewardsOpened\(\$\{[^}]*\},\$\{[^}]*\}\)$/,   // the qeval read
];
/* SCANNED OVER THE BYTES THAT SHIP, which is the only text a reader can meet.
   Two earlier versions of this got the scope wrong in opposite directions: a
   backtick regex over the whole file matched from one backtick to the next ACROSS
   code — the overlay is one 800KB file of nested template literals — and a
   line-by-line filter for comments missed every continuation line, because this
   codebase writes block comments whose second line starts with prose rather than
   a star. Both reported comments as copy, including the paragraph at the top of
   this file that QUOTES the bug.
   deploy.sh strips comments before it uploads, and strip-comments.js is that same
   stripper, harnessed by strip_test. Running it here means this check reads what
   the reader downloads — a note about the word cannot fail it, and a sentence
   containing the word cannot hide in one.
   AND PROSE IS TOLD FROM AN API NAME BY A SPACE. "OpenRewards" and
   "RewardsOpened(${s},${i})" have none; every sentence a reader is shown has one.
   That is the discriminator, and it is why the toast — which built its sentence by
   CONCATENATION, so the word was never inside a literal at all — needs the
   separate arm below rather than a cleverer scan. */
const shipped = require("../../scripts/strip-comments.js").stripHtml(src).out;
const offenders = [];
for (const raw of shipped.split("\n")) {
  for (const m of raw.match(/"[^"\n]*"|'[^'\n]*'|`[^`\n]*`/g) || []) {
    const body = m.slice(1, -1);
    if (!/crystall?i[sz]/i.test(body)) continue;
    if (API.some(rx => rx.test(body))) continue;
    if (!/ /.test(body)) continue;              // an API name, not a sentence
    offenders.push(body);
  }
}
ok("the word reaches no copy in the overlay", offenders.length === 0,
   offenders.slice(0, 3).map(o => JSON.stringify(o.slice(0, 70))).join("  "));

/* AND THE TOAST NAMES THE BUTTON. This is a separate arm from the scan on
   purpose: the leak was not a literal containing the word, it was a literal
   CONCATENATED with a variable holding it, which no scan of strings can see. */
ok("the sent-toast maps the entrypoint to what the button said",
   /const TX_SENT = \{[\s\S]{0,400}OpenRewards:\s*"the reward draw"/.test(src));
ok("...and the toast reads that map rather than the raw name",
   /"Sent\. " \+ \(TX_SENT\[func\] \|\| func\) \+ " is on its way\."/.test(src));

/* THE REALM'S OWN LINE, which gnoweb renders and which no web check can see. */
ok("the realm's rendered summary says 'rewards open'",
   /"- rewards open — pools \("/.test(render));
ok("...and no longer says the other word", !/rewards rewardsOpened/.test(render));

/* THE FIGURE THAT USED TO VANISH. Before the draw opens the ticket says what the
   claim has earned; after it opened, the ticket showed pull buttons and no total.
   "drawn" rather than "unclaimed" is forced by the chain: drawWinners, drawAuthor
   and drawAnswerer are set once and never decremented, and PullState answers for
   one address, so no global unclaimed figure is published to print. */
ok("the ticket still states the draw's size after it is opened",
   /<span class="l">Rewards drawn<\/span>/.test(src));
ok("...and it is the same three pools the pre-open row totalled",
   /Rewards drawn[\s\S]{0,300}ccPlain\(\(\(d\.draw&&d\.draw\.w\)\|\|0\) \+ \(\(d\.draw&&d\.draw\.a\)\|\|0\)/.test(src));

/* AND THE POOL THAT IS NOT IN THAT SUM IS STILL STATED. The carrot is rightly
   excluded from the total above — it decrements as it is pulled and the other
   three never do — but excluding it from a sum is not a reason to leave it
   unsaid. On the seeded covid court every crystallized claim drew zero into the
   three slices while holding a real carrot pool, and fillTicketPulls removes the
   carrot button from anyone who cannot pull it, so the ticket read "Rewards
   drawn 0.00 CC" and nothing else on a claim with money in it.
   Reported as: it says rewards drawn 0.00, but what is the total? */
ok("a carrot pool is stated as a figure, not only as a button attribute",
   /<span class="l">Voter pool left<\/span>/.test(src)
   && /Voter pool left[\s\S]{0,160}ccPlain\(d\.draw\.carrot, slug\)/.test(src));
ok("...and it is shown whenever there IS one, not only when the reader may pull it",
   /\(\(\(d\.draw&&d\.draw\.carrot\)\|\|0\) > 0/.test(src));
ok("...while staying out of the drawn total, which is the three fixed slices",
   !/ccPlain\(\(\(d\.draw&&d\.draw\.w\)[\s\S]{0,200}d\.draw\.carrot[\s\S]{0,20}\)\)/.test(src));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
