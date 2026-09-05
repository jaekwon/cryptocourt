#!/usr/bin/env node
// Truncation that does not sever a character.
//
// WHY THIS EXISTS. Four sites cut a claim title with `t.slice(0, n-1) + "…"` and
// one bisected `t.length` to fit a map label. .slice() and .length both count
// UTF-16 CODE UNITS, and an astral character is a surrogate PAIR of two units —
// so a cut landing between the halves leaves a lone surrogate, which the browser
// draws as U+FFFD. Measured before the fix: a title of 🔥 came back ending
// "\ud83d…", and one of 𓂀 ending "\ud80c…".
//
// 𓂀 IS NOT A HYPOTHETICAL HERE. The demo data in this repo names a folder
// "\u{13080} Reading room", so the overlay already carries astral text in its own
// fixtures — and a claim title is arbitrary text from whoever filed it.
//
// THE WIDTH IS THE SECOND HALF, and the quieter one. `.length` counts units, so a
// 44-character budget spent on emoji showed 23 characters. The reader saw half
// the title with no indication the cut had anything to do with the script it was
// written in.
//
// BMP TEXT WAS NEVER AFFECTED, which is exactly why this survived four copies:
// Cyrillic, Greek and ordinary CJK are one unit each, so every non-astral script
// cut correctly. That is the inverse of the same bug in the Go and realm halves
// of this codebase, where CJK was the visible case and emoji merely joined it.
// Three encodings, three different sets of characters that break, one rule.
const { fn } = require("./srcslice");

let fail = 0;
const ok = (n, c, d) => { if (!c) { fail++; console.log("FAIL:", n, d || ""); } else console.log("ok:", n); };

// `const` inside eval() does not leak to this scope; function declarations do.
const clip = eval(fn("clipText") + "; clipText");

// A lone surrogate is a high one not followed by a low, or a low not preceded by
// a high. This is the assertion that would have failed before the fix.
const LONE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/;
const cps = s => Array.from(s).length;

// Every one of these is longer than the budget in CHARACTERS, so every one is cut.
for (const [name, body] of [
  ["emoji", "\u{1F525}".repeat(60)],
  ["hieroglyph (the demo folder's own glyph)", "\u{13080}".repeat(60)],
  ["astral + latin", ("a\u{1F525}").repeat(40)],
  ["cyrillic (BMP — was already correct)", "ф".repeat(60)],
  ["cjk (BMP — was already correct)", "転".repeat(60)],
]) {
  const got = clip(body, 44);
  ok(`${name}: truncation left a lone surrogate: ${JSON.stringify(got.slice(-4))}`, !LONE.test(got));
  ok(`${name}: asked for 44 characters, got ${cps(got)}`, cps(got) === 44);
  ok(`${name}: a cut body must say it was cut`, got.endsWith("…"));
}

// THE PAIRED POSITIVE: inside the budget, the string comes back untouched — so
// this is not a formatter that mangles everything it is handed.
for (const body of ["a short claim title", "\u{1F525}\u{1F525}", "\u{13080} Reading room"]) {
  ok(`a short body must pass through whole: ${JSON.stringify(body)}`, clip(body, 44) === body);
}

// The boundary, either side. An off-by-one here abridges a title that fits.
const exact = "\u{1F525}".repeat(44);
ok("exactly n characters must not be truncated", clip(exact, 44) === exact);
ok("one over the budget must cut to exactly the budget", cps(clip("\u{1F525}".repeat(45), 44)) === 44);

// Degenerate inputs, because these run on `(data.claims[id]||{}).title || ""`
// and on a court name that may not have loaded yet.
ok("an empty string stays empty", clip("", 44) === "");
ok("null renders as nothing, not \"null\"", clip(null, 44) === "");
ok("undefined renders as nothing", clip(undefined, 44) === "");

// And mapClipW, the fifth site: it bisects `t.length`, so `mid` can land between
// surrogate halves. It needs mapTextW, which measures rendered width in a
// browser, so the measurement is stubbed.
//
// THE STUB COUNTS CODE UNITS, AND THAT IS THE WHOLE TEST. The first version of
// this file stubbed it with Array.from(s).length — code POINTS — and the
// mutation survived: measured in characters, the search always converges on an
// even index for an all-emoji label, so the pair is never split and the broken
// version passes. A stub can hide the bug it was written to find.
//
// Units are also the truer model. Real mapTextW measures pixels in a proportional
// face, which has no reason to align with character boundaries — the search can
// stop anywhere, which is exactly the hazard. Verified by construction: at these
// two widths the pre-fix code returns "🔥\ud83d…" and "\udd25a\ud83d…".
const mclip = eval(
  "function mapTextW(s){ return s.length; }\n" + fn("mapClipW") + "; mapClipW");
for (const [name, body, px] of [
  ["emoji", "\u{1F525}".repeat(60), 20],
  ["astral + latin", ("a\u{1F525}").repeat(40), 21],
  ["hieroglyph", "\u{13080}".repeat(60), 20],
]) {
  const got = mclip(body, px, 12, "");
  ok(`mapClipW ${name}: left a lone surrogate: ${JSON.stringify(got.slice(-4))}`, !LONE.test(got));
  ok(`mapClipW ${name}: a clipped label must say it was clipped`, got.endsWith("…"));
  ok(`mapClipW ${name}: clipped to ${got.length} units, over the ${px} it was given`, got.length <= px);
}
// It fits: a label already inside the width is returned unchanged and unmarked.
ok("mapClipW must not mark a label that already fits",
  mclip("\u{1F525}\u{1F525}", 20, 12, "") === "\u{1F525}\u{1F525}");

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
