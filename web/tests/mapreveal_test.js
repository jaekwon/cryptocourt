#!/usr/bin/env node
// What the map opens on, and what a set drags with it when you open one.
//
// TWO RULES, AND THEY ARE THE SAME RULE. Opening a set reveals everything filed
// under it; and the map's own opening view is the set of 𓂀 sets hanging off the
// court root, opened. So the default is not a separate feature — it is the click,
// applied by whoever filed the titles.
//
// THE CHAIN IS THE INTERESTING HALF. A 𓂀 set nested under a 𓁼 one does NOT
// open. The mark says "show this when the map opens", but a reader cannot be
// shown the inside of a drawer that is shut: the enclosing set is the thing that
// was concealed, and revealing its contents anyway would publish exactly what
// the 𓁼 was there to withhold. So the descent stops at the first shut door and
// the marks below it are never consulted.
//
// AND WHY REVEALED IS DERIVED RATHER THAN STORED. SEL holds the picks only. The
// first draft pushed each folder's subtree into SEL at click time, and it was
// wrong in two directions that a derived set does not have:
//   - closing a set left its contents selected, because the removal took one
//     entry out of a list that now held its descendants as peers;
//   - a claim filed in TWO revealed sets was dropped by whichever closed first,
//     though the other still held it.
// Both are the same mistake: a cache of a computation, kept beside the inputs,
// allowed to disagree with them.
const { src, slice, fn } = require("./srcslice");

let fail = 0;
const ok = (n, c, d) => { if (!c) { fail++; console.log("FAIL:", n, d || ""); } else console.log("ok:", n); };

/* The three are consts inside the map's mount closure, so they are lifted as a
   region and evaluated over a fake layout rather than called through the DOM. */
const body = slice("const subtreeOf = box =>", "function paint(){");
let L, SEL;
/* OUT is declared beside SEL in the mount, outside the region lifted here, so
   the harness supplies it the way it supplies SEL and selKey. It holds the keys
   a reader put out by hand — a hole in the reveal that a parent would otherwise
   keep filling. */
const OUT = new Set();
const selKey = x => x.kind === "folder" ? "f" + x.fid
  : x.kind === "claim" ? "c" + x.id : "court";
const { subtreeOf, revealed, defaultReveal } =
  eval("(function(){ " + body + " return {subtreeOf, revealed, defaultReveal}; })()");

/* THE FIXTURE IS A LAYOUT, NOT A TREE, and that distinction is the whole reason
   the first version of this feature did nothing on the real site. mapLayout does
   not return the tree — it returns BOXES, fresh objects with a curated field set,
   and `kids` is not among them. A fixture shaped like the tree let every
   assertion here pass while the page revealed nothing, because L.court.kids and
   L.folders[i].kids are both empty in a browser. So the fixture now carries
   `kidF`/`kidC` — the layout's own "f3"-style keys — exactly as the boxes do.

      court
        ├── A  𓂀   claim 1,  B 𓁼 (claim 2)
        ├── C  𓁼   claim 3,  D 𓂀 (claim 4)     <- D is the buried one
        └── E  𓂀   claim 5                                              */
const mk = (kidF, kidC, focus) => ({kind:"folder", focus, kidF, kidC});
const L5 = {
  0: mk(["f1"], [1], true),    // A
  1: mk([],     [2], false),   // B
  2: mk(["f3"], [3], false),   // C
  3: mk([],     [4], true),    // D
  4: mk([],     [5], true),    // E
};
const withCourt = kidF => ({court: {kidF, kidC: []}, folders: L5});
L = withCourt(["f0", "f2", "f4"]);

const keys = arr => [...arr].sort().join(" ");

/* SUBTREE: everything below, at every depth, sets and claims alike. */
ok("a set drags its claims", keys(subtreeOf(L5[0]).map(selKey)).includes("c1"));
ok("...and its subsets", keys(subtreeOf(L5[0]).map(selKey)).includes("f1"));
ok("...and their claims, at depth", keys(subtreeOf(L5[0]).map(selKey)).includes("c2"));
ok("...and nothing above or beside it",
   keys(subtreeOf(L5[0]).map(selKey)) === "c1 c2 f1");
ok("a childless set drags nothing", subtreeOf(mk([], [], true)).length === 0);
ok("...and a box with neither list does not throw",
   subtreeOf({kind:"folder"}).length === 0);
ok("...and neither does one that is not there at all", subtreeOf(undefined).length === 0);
/* A CYCLE CANNOT HANG THE PAGE. `parent` comes off the chain and a court sets it;
   mapTree refuses to descend into a loop, and this is the second fence rather
   than the first, because a walk over arbitrary chain data that can hang the tab
   should not rest on somebody else's check staying correct. */
L = {court: {kidF: [], kidC: []}, folders: {0: mk(["f1"], [], true), 1: mk(["f0"], [], true)}};
ok("a set filed inside itself terminates", keys(subtreeOf(L.folders[0]).map(selKey)) === "f0 f1");

/* THE DEFAULT: the court's 𓂀 children, and only those. */
L = withCourt(["f0", "f2", "f4"]);   // the cycle case above left L on its own fixture
const def = defaultReveal();
ok("the map opens on the court's revealed sets", keys(def.map(selKey)) === "f0 f4");
ok("...not on a concealed one", !def.some(p => p.fid === 2));
ok("...and not on a revealed set filed under a concealed one — the chain",
   !def.some(p => p.fid === 3));

/* A COURT THAT REVEALED NOTHING OPENS ON NOTHING, which is how every map behaved
   before any of this existed. This is the case that must not regress: most
   courts have no 𓂀 anywhere. */
L = withCourt(["f2"]);
ok("a court with no revealed set opens empty", defaultReveal().length === 0);
L = {court: null, folders: {}};
ok("...and so does one whose layout has no court yet", defaultReveal().length === 0);

/* REVEALED = PICKS ∪ THEIR SUBTREES, recomputed, never stored. */
L = withCourt(["f0", "f2", "f4"]);
SEL = [{kind:"folder", fid:0}];
ok("opening a set reveals it and everything under it",
   keys(revealed()) === "c1 c2 f0 f1");
SEL = [];
ok("no picks reveals nothing", revealed().size === 0);
SEL = [{kind:"claim", id:7}];
ok("a claim reveals only itself", keys(revealed()) === "c7");
SEL = [{kind:"court"}];
ok("the court node reveals only itself", keys(revealed()) === "court");
ok("a pick naming a set the layout does not have is ignored, not fatal",
   (SEL = [{kind:"folder", fid:99}], keys(revealed()) === "f99"));

/* CLOSING IS EXACT, which is the reason for deriving. Two sets both holding
   claim 4: closing one must not take it away from the other. */
L = {court: {kidF: ["f3", "f5"], kidC: []},
     folders: {3: mk([], [4], true), 5: mk([], [4], true)}};
SEL = [{kind:"folder", fid:3}, {kind:"folder", fid:5}];
ok("a claim filed in two open sets is revealed once", keys(revealed()) === "c4 f3 f5");
SEL = [{kind:"folder", fid:5}];
ok("...and closing one of them leaves it revealed by the other",
   keys(revealed()) === "c4 f5");
SEL = [];
ok("...and closing both takes it away", revealed().size === 0);

/* THE WIRING, checked in the source because the above ran on a fake layout. */
ok("paint reads the derived set, not SEL", /const held = revealed\(\);/.test(src));
ok("...and dims from the same set, so the eye and the dim cannot disagree",
   /dimTo\(\[\.\.\.held\]\);/.test(src));
ok("the map seeds its picks from the court before the first draw",
   /SEL = defaultReveal\(\);\s*\n\s*put\(\);/.test(src));
/* AND EVERY DRAW REPAINTS. put() replaces the SVG outright, so anything paint()
   wrote is gone with the nodes that carried it — switching titles↔ids cleared the
   selection long before this feature, and would now reset every open eye too. */
ok("a redraw puts the reader's state back on the new nodes",
   /apply\(\); paint\(\); \}/.test(src));
ok("select() pushes the pick alone, leaving the subtree to be derived",
   /SEL\.push\(next\);\s*\n\s*paint\(\);/.test(src));

/* THE PASSENGERS. Two rebuilds filter a folder tree by claim id and construct a
   fresh object naming what they keep, and each has now dropped a field that
   merely rides along: `img` first, then `born`, then `focus`. All three failed
   the same way — silently, as an absence, on a surface where absence is a
   legitimate state — and `focus` was found only by a browser check asking the
   dataset what it declared and the page what it drew.
   NARROW ON PURPOSE. The file's own note explains why a blanket parity guard
   between the three folder builders was rejected: five fields differ between
   them for good reasons, and the guard had to name the passengers anyway. So
   this names the three that have actually been lost, which is a list with
   evidence behind every entry rather than a rule nobody can satisfy. */
for (const [what, body] of [
  ["the curation rebuild", fn("curFilterFolders")],
  ["the drawn-window filter", slice("const filterFolders = fs =>", "const curFolders =")],
]) {
  for (const field of ["img", "born", "focus"])
    ok(`${what} carries ${field} through`,
       new RegExp(`${field}:\\s*f\\.${field}\\b`).test(body), field);
}

/* THE EYE FOLLOWS THE STATE, not the filing. A set the reader opened shows the
   open mark even though its title carries 𓁼, and vice versa. */
ok("the mark on a map set is redrawn from what is revealed",
   /text\.mset["'\)\]]*\)\.forEach[\s\S]{0,200}held\.has\("f" *\+ *t\.dataset\.fid\)/.test(src));
ok("...swapping between the two marks the realm accepts",
   /mk\.textContent = open \? SET_MARK : SHUT_MARK/.test(src));
/* THE MARK LIVES IN ITS OWN TSPAN so the swap can leave the <title> alone.
   `t.textContent = mark` on the <text> replaces every child, and the title IS a
   child — the accessible description of the badge would have been deleted by the
   first click, silently, on a surface where the glyph is the only other thing
   said about the set's state. */
ok("the mark is a tspan beside the title, not the text's whole content",
   /<tspan class="msetmark">\$\{mark\}<\/tspan>/.test(src)
   && /mk = t\.querySelector\(["'`]\.msetmark/.test(src));
ok("...and the words are re-said for the state it swapped to",
   /ti\.textContent = setOpensWords\(open\)/.test(src));
/* AND THE RING MOVES WITH THE PUPIL. mapSvg draws the badge's outline centred on
   the nudged glyph; leaving it at the filed position while the glyph rises puts
   the mark through the top of its own outline — which is the misalignment the
   nudge exists to prevent, arriving by the other door. */
ok("the ring carries its open centre too", /data-cy0="/.test(src));
ok("...and paint moves it by the same nudge",
   /ring\.setAttribute\("cy", \(cy0 - dy\)/.test(src));
/* AND THE PUPIL DOES NOT MOVE THROUGH THE SWAP. 𓂀 and 𓁼 sit on different
   baselines in the font, so drawing them at one y makes the eye jump as it
   opens. The layout stores the open baseline and the em; the shut glyph is
   nudged up from it. */
ok("the open baseline and the em are carried on the node",
   /data-y0="/.test(src) && /data-es="/.test(src));
ok("...and the shut mark is drawn up from that baseline",
   /const dy = open \? 0 : es \* 0\.22;/.test(src)
   && /setAttribute\("y", \(y0 - dy\)/.test(src));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
