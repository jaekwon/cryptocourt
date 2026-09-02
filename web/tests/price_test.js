// What the coin price tile says, and what it must never say.
//
// WHY THIS EXISTS. Reported as: "it says the price is 0 for a new kourt, can't
// be true". It was reading `0` under a heading that says "coin price", for a
// court where nothing had been minted.
//
// THE MATHS WAS RIGHT AND THE SENTENCE WAS WRONG, which is the whole reason this
// file is here. The curve is Price(s) = s/d — the MARGINAL price of the next
// unit — so at supply 0 it genuinely is zero. But Cost(from, delta) is
// ceil((s1² − s0²) / 2d), so from empty:
//
//     1 unit                1 µGNOT
//     1 coin (1e6 units)  500 µGNOT
//     100 coins       5,000,000 µGNOT
//
// Nothing is free. A reader shown "0" concludes otherwise, and priceText had no
// test at all — five branches of display logic, none covered, one of them
// telling people a coin costs nothing.
//
// THE TILE AND THE JOIN PANEL QUOTE DIFFERENT NUMBERS ON PURPOSE: this one is the
// next unit's price, that one is the average over the units actually taken,
// which on a rising curve is always higher. The copy has to name which it is or
// the two read as a contradiction.
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a < 0) throw new Error("missing " + from);
  const b = src.indexOf(to, a); if(b < 0) throw new Error("missing " + to);
  return src.slice(a, b);
}
let fail = 0;
const ok = (n, c) => { if(!c){ fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

/* TAKEN BY THEIR OWN CLOSING BRACE, not by whatever function happens to follow.
   Slicing "from fmtN to ugnot" and "from priceText to courtStatsHtml" is the
   obvious thing and it is wrong twice over: neither pair is adjacent, so both
   slices dragged in everything between — including code that touches `document`,
   which does not exist under node. This file died on "document is not defined"
   while testing two pure string functions. A function ends at the first line
   that is exactly "}", which is true of every function in this file's style. */
function fn(name){
  const a = src.indexOf("function " + name + "(");
  if(a < 0) throw new Error("missing function " + name);
  const b = src.indexOf("\n}", a);
  if(b < 0) throw new Error("unterminated function " + name);
  return src.slice(a, b + 2);
}
eval(fn("fmtN"));
eval(fn("priceText"));

// ---------------------------------------------------------------- the zero case
ok("a court with nothing minted shows no price, not a zero",
   priceText(0, 0) === "—");
ok("...and specifically not the string that started this",
   priceText(0, 0) !== "0");

// ------------------------------------------------------------- the ordinary case
ok("a live price is the figure itself", priceText(118, 1e8) === "118");
ok("...formatted with separators once it is large", priceText(1234567, 1e12) === "1,234,567");

/* SUB-µGNOT IS NOT ZERO EITHER, and this branch already existed — a court with
   supply but a marginal price that floors to 0 shows fractional µGNOT rather
   than rounding down to nothing. Covered here because it is the same class of
   lie as the one above and had no test either. */
ok("a price under one µGNOT is shown as a fraction, not 0",
   priceText(0, 5e8) === "0.5");
ok("...and a price too small even for that says so",
   priceText(0, 1e5) === "<0.001");

// ------------------------------------------------------------------- the copy
/* THE TILE CARRIES NO PROSE, by decision. It used to explain three things at
   once — which of the two prices this is, that the GNOT is burned, and that a
   coin is a million units — none of which a reader standing on a court page has
   asked yet, and the unit conversion meant nothing without the arithmetic it
   was for.
   WHAT IS GIVEN UP: the tile shows the NEXT unit's price and the Join panel
   shows the AVERAGE over the units actually taken, which on a rising curve is
   higher. Both are right and they differ. The Join panel names its own figure
   ("Average price you pay") and states the burn beside the button, so the
   distinction is made where the two numbers are compared rather than on a page
   that shows only one of them. Asserted so that re-adding a sentence here is a
   decision and not a drift back. */
const tile = slice('statTile("coin price"', '// The emitted split is a footnote');
ok("the price tile carries no explanatory sub-line",
   !/the next unit's price|1,000,000 units|GNOT is burned/.test(tile));
ok("...and the Join panel still names its own figure as an average",
   src.includes("Average price you pay"));
ok("...and still states that the GNOT does not come back",
   src.includes("cannot be sold back to the court"));
/* THE TILE IS A FIGURE, FULL STOP — no sub-line in either branch.
   The copy here was trimmed three times, each on the same feedback, and this is
   the end of it: a clause explaining the curve went, then the reason the quote
   is per unit, then the remaining three sentences and the 1,000,000-unit
   conversion. The last of those was the clearest signal — "i still don't know
   what this means" — a ratio with no arithmetic beside it to use it on.
   The zero branch has no sub either; an em dash under "coin price" already says
   there is no price yet. */
ok("no sub-line in either branch", !/\.\s*`\)/.test(tile) && !tile.includes("units."));
ok("...and no unit suffix beside an em dash",
   /s\.minted===0\? priceText\(s\.price, s\.minted\)/.test(tile));
ok("...and the µGNOT/unit suffix stays on a real figure",
   /µGNOT\/unit/.test(tile));

console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
process.exit(fail ? 1 : 0);
