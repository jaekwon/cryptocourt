// The holder leaderboard's reading of the chain, and its wiring.
//
// WHY THE PARSER IS THE PART WORTH TESTING. TopHolders answers with
// "address:balance" rows joined by ";", and every field in it comes from a
// stranger's chain: a malformed row, a truncated page, an address the reader has
// never seen. A parser that throws takes the whole page down; one that coerces
// silently puts a wrong balance next to a real address, which is worse, because
// a leaderboard is read as a fact about people.
//
// The rendering is asserted at the source level rather than by driving the
// route: the route is async and chain-backed, and what can go wrong in it that a
// source check cannot see — layout, contrast — is not what this file is for.
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const { fn } = require("./srcslice");
let fail = 0;
const ok = (n, c) => { if(!c){ fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

eval(fn("parseHolders"));

// ------------------------------------------------------------------ the parser
{
  const rows = parseHolders("g1aaa:5000000;g1bbb:250000");
  ok("rows come back in the order the chain sent them",
     rows.length === 2 && rows[0].who === "g1aaa" && rows[1].who === "g1bbb");
  ok("...with the balance as a number, not a string",
     rows[0].bal === 5000000 && typeof rows[0].bal === "number");
}
ok("an empty answer is an empty list, not a row", parseHolders("").length === 0);
ok("...and so is a null one", parseHolders(null).length === 0);

/* A ROW WITHOUT A SEPARATOR IS DROPPED, NOT GUESSED. The alternative is an
   entry with an address and no balance, which renders as a holder of nothing —
   a person on a leaderboard who does not belong there. */
ok("a row with no colon is skipped, and the good rows survive", (() => {
  const r = parseHolders("nocolon;g1ok:12");
  return r.length === 1 && r[0].who === "g1ok" && r[0].bal === 12;
})());
ok("a row with no balance is skipped", parseHolders("g1aaa:").length === 0);
ok("a non-numeric balance is skipped", parseHolders("g1aaa:abc").length === 0);
ok("a row with no address is skipped", parseHolders(":500").length === 0);

/* lastIndexOf, not split(":"). An address carries no colon today, so a split
   would work — and it would break silently the day one did, taking the balance
   from the wrong field. The separator is the LAST colon by definition of the
   format, and the parser says so. */
ok("the balance is taken from the last colon, not the first",
   parseHolders("g1:odd:900")[0].bal === 900 &&
   parseHolders("g1:odd:900")[0].who === "g1:odd");

// ------------------------------------------------------------------ the wiring
ok("the leaderboard has a route", /on\(\/\^\\\/c\\\/\(\[a-z0-9-\]\+\)\\\/holders\$\//.test(src));
ok("...reachable from the court page's own row",
   src.includes('href="#/c/${esc(slug)}/holders">holders'));
ok("...and it asks the chain for the page and the count together",
   src.includes("one(`HolderCount(${s2})`)") && src.includes("one(`TopHolders(${s2},${n|0})`)"));

/* THE CAVEAT IS NOT OPTIONAL. TopHolders ranks coin HELD; staked coin sits in
   the court's custody, so a committed staker can rank below somebody who never
   staked and the number alone cannot say why. The sentence is the realm's,
   mirrored here, and check-web-constants fails if the two drift. */
ok("the page prints what the ranking leaves out",
   /const HOLDERS_NOTE = "Ranked by coin held\./.test(src)
   && src.includes("${esc(HOLDERS_NOTE)}"));
ok("...naming staked coin and whose custody it is in",
   /HOLDERS_NOTE[^\n]*staked/.test(src) && /HOLDERS_NOTE[^\n]*custody/.test(src));

/* A share, not just a figure: a balance alone is unreadable — so many of what,
   out of what — and the share is the thing a holder came to see after buying. */
ok("every row carries its share of supply", src.includes("const pct = b => supply>0? (100*b/supply) : 0;"));
ok("...and a share too small to round is not shown as 0.0%",
   src.includes('pct(r.bal)>=0.1? pct(r.bal).toFixed(1) : "<0.1"'));
ok("the reader's own row is marked", src.includes('const you = r.who===mine;')
   && src.includes('class="youare"'));
ok("an empty court says so rather than drawing an empty table",
   src.includes("Nobody holds this court's coin yet."));

console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
process.exit(fail ? 1 : 0);
