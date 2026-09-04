#!/usr/bin/env node
// How an amount of court coin is written, and where its symbol belongs.
//
// WHY THIS HARNESS EXISTS. Nothing tested the money formatters at all — not
// ccFigure, not cc, not ccRow — and the claim page's "Reward to open" row shipped
// printing the symbol TWICE: cc() ends in ccSymHtml, and the call site appended
// ccSym() after it, so the row read "596 µKourt:COVID KOURT:COVID". A reader
// reported it before any check did, because there was no check to do it.
//
// THE TWO SHAPES ARE A DELIBERATE PAIR, and the distinction is the whole design:
//
//   cc(n, slug)   names the coin, because most callers need it to. The account
//                 popover and the wallet list balances ACROSS courts, and "0.74"
//                 there is a number with no denomination.
//   ccPlain(n)    says the amount alone, in CC, for a surface that has already
//                 said which court — a claim page has it in the crumbs, the
//                 heading and the URL, so repeating KOURT:COVID beside every
//                 figure spends width on something the reader already knows.
//
// AND ccPlain KEEPS ONE UNIT. ccFigure drops to a micro prefix below 0.01 CC,
// which renders a small reward as "596 µ" — a different unit from every other
// figure on the same page, for no reason except that the number is small.
// ccPlain spends decimals instead, and the floor it has to clear is that a
// non-zero amount is never shown as 0.00: that is the only thing the micro
// prefix was protecting against.
const fs = require('fs');
const { slice, src } = require("./srcslice");
let fail = 0;
const ok = (n, c) => { if (!c) { fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

global.fmtN = n => new Intl.NumberFormat('en-US', {maximumFractionDigits: 1}).format(n);
global.esc = s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
  .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
eval(slice('function ccSym(', 'function ugnot('));

// ---- ccPlain: one unit, enough decimals, no symbol ------------------------
ok("a whole amount reads in CC with two decimals", ccPlain(17_000_000) === "17.00 CC");
ok("a sub-unit amount keeps two decimals", ccPlain(740_000) === "0.74 CC");
ok("zero is zero, not a fraction", ccPlain(0) === "0.00 CC");
ok("a missing amount is zero rather than NaN", ccPlain(undefined) === "0.00 CC");
/* THE REPORTED FIGURE. 596 base units is 0.000596 CC — under ccFigure's micro
   threshold, which is what produced "596 µ" on the claim page. */
/* WHICH ARM GUARDS WHAT, because an ablation showed the two are not the same
   check. The [2,4,6] loop picks the SHORTEST form that is not zero — that is what
   the 0.74 and 0.0006 arms pin, and narrowing the loop fires them. The floor
   under all of it is the final toFixed(6), which is why capping the loop at two
   decimals still returns 0.000005 rather than 0.00: the arm below keeps passing
   through that ablation, correctly, because the fallback is doing its job. */
ok("the amount that was shown as 596 µ reads as CC", ccPlain(596) === "0.0006 CC");
ok("...and an amount smaller still does not round to a false zero",
   ccPlain(5) === "0.000005 CC" && parseFloat(ccPlain(5)) > 0);
ok("a large amount keeps its thousands separator", ccPlain(1_234_567_890) === "1,234.6 CC");
ok("no micro prefix survives anywhere in it",
   [0, 5, 596, 740_000, 17_000_000, 1_234_567_890].every(n => !ccPlain(n).includes("µ")));
ok("and it names no court",
   [5, 596, 740_000].every(n => !/KOURT|ccsym/i.test(ccPlain(n))));

// ---- cc() still names the coin, because its callers need it ---------------
// Asserted as the PAIR: the point is not that ccPlain drops the symbol, it is
// that the two formatters differ, so a future edit cannot quietly make one the
// other and leave the wallet listing bare numbers across courts.
ok("cc() still carries the court's symbol", /ccsym/.test(cc(740_000, "covid")));
ok("...and ccPlain does not", !/ccsym/.test(ccPlain(740_000)));

// ---- the regression itself, in the source --------------------------------
/* A SOURCE CHECK, deliberately: the row is built inside the claim route's
   template and cannot be called from here without the whole page. What can be
   pinned is the SHAPE that was wrong — cc() already ends in the symbol, so any
   call site that appends ccSym() to it prints the symbol twice. */
ok("no call site appends the symbol to a formatter that already carries it",
   !/cc\([^)]*\)\s*\+\s*ccSym\(/.test(src));
ok("the reward row uses the plain formatter",
   /Reward to open[\s\S]{0,400}ccPlain\(d\.quote\.w \+ d\.quote\.a \+ d\.quote\.ans\)/.test(src));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
