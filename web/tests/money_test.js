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

// ---- ccPlain WITHOUT a court: one unit, enough decimals, the bare word ----
// This is the fallback arm now, not the only arm. A caller with no court in hand
// has nothing to draw a mark from, and "CC" is still the right word for an
// amount of court coin in the abstract — so every figure assertion below is
// about the SHAPE OF THE NUMBER and stays exactly as it was.
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

// ---- given a court, BOTH name it ------------------------------------------
/* THE CONTRACT CHANGED HERE, and this is what it changed to. It used to be
   "cc() names the coin and ccPlain does not", and the claim page took the second
   one everywhere — so "accuracy 0.00 · author 0.00 · answerer 0.00 · voters
   0.0001 CC" sat under tiles wearing the gold bar, the same coin drawn two ways
   on one page. Reported exactly that way.
   What the original reasoning actually established was that the unit should not
   be REPEATED per figure — which is why ccFig has no micro mode and why a row
   says its unit once. It never established that the one surviving unit should be
   spelled as an initialism. So the unit is still said once, and now said in the
   product's own mark.
   Still asserted as a PAIR, for the reason the old comment gave: the two
   formatters must stay distinguishable, so a future edit cannot quietly collapse
   them. The difference is no longer symbol-vs-none — it is that cc() carries the
   µ prefix machinery for a wallet listing across courts, and ccPlain keeps one
   unit and spends decimals for a page that is already inside one court. */
ok("cc() carries the court's symbol", /ccsym/.test(cc(740_000, "covid")));
ok("...and so does ccPlain, once it is told which court",
   /ccsym/.test(ccPlain(740_000, "covid")));
ok("...with the figure unchanged either way",
   ccPlain(740_000, "covid").startsWith("0.74 ") && ccPlain(740_000) === "0.74 CC");
ok("...and no court means the bare word, not an empty mark",
   ccPlain(740_000) === "0.74 CC" && !/ccsym|<span/.test(ccPlain(740_000)));
/* The two still differ where it matters: cc() drops to a µ prefix for a small
   amount and ccPlain never does. That is the collapse this pair is guarding. */
ok("...and the two still disagree about small amounts",
   /µ/.test(cc(596, "covid")) && !/µ/.test(ccPlain(596, "covid")));
/* ccRow says the unit once, after ALL the figures — the row that was reported. */
ok("a row of figures wears one mark, at the end",
   (ccRow([["accuracy",0],["author",0],["answerer",0],["voters",55]], "covid")
     .match(/ccsym/g) || []).length === 1);
ok("...and without a court it is still the bare word",
   ccRow([["a",0],["b",55]]).endsWith(" CC"));

// ---- the regression itself, in the source --------------------------------
/* A SOURCE CHECK, deliberately: the row is built inside the claim route's
   template and cannot be called from here without the whole page. What can be
   pinned is the SHAPE that was wrong — cc() already ends in the symbol, so any
   call site that appends ccSym() to it prints the symbol twice. */
ok("no call site appends the symbol to a formatter that already carries it",
   !/cc\([^)]*\)\s*\+\s*ccSym\(/.test(src));
ok("the reward row uses the plain formatter",
   /Reward to open[\s\S]{0,400}ccPlain\(d\.quote\.w \+ d\.quote\.a \+ d\.quote\.ans, slug\)/.test(src));

// ---- a row of figures shares one unit ------------------------------------
/* THE REWARD POOLS. ccRow had a mixed-scale fallback: when some figures were
   micro and some were not, each carried its own "µKOURT:COVID". A young court
   hits that every time — three pools at 0.00 beside a voter pool of 55 base
   units — so the row printed the court's symbol FOUR times and a µ. ccFig has no
   micro mode, so there is no mixed scale left to fall back to.
   Asserted on the shape that reported it, and on a mature row beside it, so a
   reintroduced fallback fails on one of the two. */
eval(require('fs').readFileSync(require('path').join(__dirname,'..','index.html'),'utf8')
  .match(/function ccRow\([\s\S]*?\n\}/)[0]);
ok("a young court's pools read as one unit, in CC",
   ccRow([["accuracy",0],["author",0],["answerer",0],["voters",55]])
     === "accuracy 0.00 · author 0.00 · answerer 0.00 · voters 0.0001 CC");
ok("...and a mature row does too",
   ccRow([["accuracy",1_644_800],["author",164_480],["answerer",0],["voters",12_320]])
     === "accuracy 1.64 · author 0.16 · answerer 0.00 · voters 0.01 CC");
ok("...with no micro prefix and no court symbol anywhere in it",
   !/µ|KOURT|ccsym/i.test(ccRow([["a",0],["b",55]])));

// ---- which surfaces say the symbol, and which do not ---------------------
/* THE SWEEP, AND ITS ONE EXCEPTION. A claim page names its court in the crumbs,
   the heading and the URL, so the stake bar and the chip row under the chart read
   in CC. The vote-lock modal does NOT: it is a disclosure under the §7.4 house
   style, votelock_test pins "this vote would commit N KOURT:OREM", and a
   disclosure is the one surface where the denomination in full is worth its
   width. Asserted here as a PAIR so neither half can drift into the other —
   sweeping the disclosure by accident is exactly what this catches. */
ok("the stake bar reads in CC, once per side",
   /sidetag">YES<\/span> \$\{py\.toFixed\(1\)\}%<\/b> · \$\{ccPlain\(y, slug\)\}/.test(src)
   && /sidetag">NO<\/span> \$\{pn\.toFixed\(1\)\}%<\/b> · \$\{ccPlain\(n, slug\)\}/.test(src));
ok("the chip under the chart reads in CC",
   /next dispute bond \$\{ccPlain\(d\.disputeBondNext, slug\)\}/.test(src));
ok("the vote-lock disclosure still names the court's own symbol",
   /this vote would commit \$\{cc\(would,slug\)\}/.test(src));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
