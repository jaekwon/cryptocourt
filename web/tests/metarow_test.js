// Meta's directory row must not print the same figure twice.
//
// WHAT WENT WRONG. The row has two forms: one figure when the franchise is
// fully claimed, two when some is still owed. Which one it used was decided by
// `BURN_ELSEWHERE > claimed` on the RAW micro-amounts — so any excess at all
// took the two-figure branch, including a rounding remainder of a few
// micro-units. Once everything had been claimed that was exactly what was
// left, and the row rendered "13,054 GNOT claimed of 13,054 GNOT earned": the
// same number twice, which reads as a mistake rather than as a total. With
// covid's own burn line above it, one figure appeared three times on the page.
// Reported that way, and fairly.
//
// WHAT IS PINNED HERE is the MECHANISM, because that is what was wrong: the
// choice must compare what a reader would SEE — gnotAmt's output — and not the
// underlying amounts. A test over the rendered strings alone could not catch
// it, since with any dataset where the two genuinely differ both versions
// agree; the bug lived only in the case where they differ by less than the
// formatter shows.
//
// THE RENDERED BEHAVIOUR WAS VERIFIED SEPARATELY, against both real datasets
// rather than a fixture, because each exercises one branch and neither can
// exercise both:
//   - the demo sample, where 2,000 is claimed of 9,780,211 burned elsewhere:
//     "2,000 GNOT claimed of 9,780,211 GNOT burned on other courts".
//   - the live chain after a reseed, where the whole franchise is claimed:
//     "13,054 GNOT burned on other courts, all of it claimed", and the figure
//     goes from appearing three times on the page to twice.
//
// metaRowLine is a closure inside the directory view and cannot be sliced out,
// which is why this reads the source rather than calling it.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');

let fail = 0;
const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

// The comparison is between rendered strings.
ok("the row chooses its form by comparing what is rendered",
   /const got = gnotAmt\(claimed\), all = gnotAmt\(BURN_ELSEWHERE\);/.test(src) &&
   /return got === all/.test(src));
// And NOT by the raw amounts, which is the form that shipped the bug.
ok("...not by the raw micro-amounts",
   !/BURN_ELSEWHERE > claimed/.test(src));
// Both branches still exist: collapsing to one form would lose the gap the
// two-figure version is for.
ok("the fully-claimed form says so in words instead of repeating the figure",
   /burned on other courts, all of it claimed/.test(src));
ok("...and the partly-claimed form still names both",
   /claimed of \$\{all\} burned on other courts/.test(src));
// The supply is already the bold figure in this cell; the line must not repeat
// it, which is what the report asked for.
ok("the line does not restate the coin supply",
   !/metaRowLine[\s\S]{0,400}cc\(s\.supply/.test(src));

console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
process.exit(fail ? 1 : 0);
