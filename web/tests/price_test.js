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
/* The tile must SAY which price it is showing. Both numbers are correct and
   they differ, so a reader comparing the tile against the Join panel needs the
   distinction on the page, not inferred. */
const tile = slice('statTile("coin price"', '// The emitted split is a footnote');
ok("the tile names this as the NEXT unit's price", /the next unit's price/.test(tile));
ok("...and points at the average as what you actually pay",
   /average over what you buy/.test(tile));
ok("the zero-supply branch says what sets the first price",
   /the first buy sets the price/.test(tile));
ok("...and does not print a unit suffix beside an em dash",
   /s\.minted===0\? priceText\(s\.price, s\.minted\)/.test(tile));
/* "1 KOURT:X = 1,000,000 units" stated a conversion without ever saying what it
   was for, which is the other half of the report — "what does 1 million units
   even mean". The copy has to give the reason, not just the ratio. */
ok("the units line explains why the quote is per unit",
   /Quoted per unit because the curve moves per unit/.test(tile));

console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
process.exit(fail ? 1 : 0);
