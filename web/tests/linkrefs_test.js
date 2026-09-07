#!/usr/bin/env node
// References inside a claim's body and inside its comments.
//
// WHAT THIS IS FOR. People write "#19" and "𓁼 Fauci" in prose, because that is
// how the page itself names those things — and it was dead text, so following a
// reference meant reading the number, going back to the docket, and finding it
// by hand.
//
// THE COURT DECIDES WHETHER A REFERENCE RESOLVES, and the two lookups that
// answer already existed for the chat rail: claimIsReal and setFidByName. This
// reuses them rather than walking the folder tree a second time, which is what
// the first draft did. The consequence worth naming: a claim page and the chat
// panel beside it can never disagree about whether #19 is real in this court.
//
// SILENCE IS NOT A LINK. A court whose count or folders were never read answers
// "no" to everything, and so does a DIFFERENT court — the one wrong answer that
// would look right is #19 here pointing at #19 somewhere else.
//
// THE ENTITY HAZARD IS THE REASON THE PATTERN IS BORROWED RATHER THAN WRITTEN.
// This runs on ESCAPED text, so an apostrophe in the body is `&#39;` — and a
// naive /#(\d+)/ turns the tail of an escaped quote into a link to claim 39.
// chat.js already had the `[^&\w]` guard for exactly this; the version first
// written here did not, and this file's first run caught it.
const { src, slice } = require("./srcslice");

let fail = 0;
const ok = (n, c, d) => { if (!c) { fail++; console.log("FAIL:", n, d || ""); } else console.log("ok:", n); };

// The page's own escaper, and the two marks, so the region under test is real.
global.SET_MARK = "\u{13080}";
global.SHUT_MARK = "\u{1307C}";
eval(slice("function esc(", "\n"));
// The court's answers, stubbed here so each case can say what this court has.
let COURT = null;
global.setNamesOf = slug => COURT && COURT.slug === slug ? Object.keys(COURT.sets) : [];
global.setFidByName = (slug, name) =>
  COURT && COURT.slug === slug && COURT.sets[name] != null ? COURT.sets[name] : null;
global.claimIsReal = (slug, id) =>
  !!COURT && COURT.slug === slug && id >= 1 && id <= COURT.top;
eval(slice("const CLAIM_REF_RE", "function claimBody(").replace(/^const /gm, "var "));

const covid = {slug: "covid", top: 30, sets: {"Fauci": "2", "Fauci grants": "7", "Lab & leak": "9"}};
const body = (t, slug) => linkRefs(esc(t), slug === undefined ? "covid" : slug);

/* ---- claim numbers -------------------------------------------------------- */
COURT = covid;
ok("a claim this court has becomes a link",
   body("see #19 for the rest") === 'see <a class="reflink" href="#/c/covid/19">#19</a> for the rest');
ok("...at the start of a paragraph too", body("#19 says otherwise").startsWith('<a class="reflink"'));
ok("a claim this court does not have stays text", body("see #4000") === "see #4000");
ok("...and so does one past the ceiling by one", body("#31") === "#31");
ok("...while the last real one links", body("#30").includes('href="#/c/covid/30"'));

/* THE ENTITY HAZARD, WHICH IS THE WHOLE REASON FOR THE `[^&\w]` GUARD. esc()
   turns an apostrophe into `&#39;`, and 39 is a real claim in this fixture — so
   a pattern without the guard links the tail of the escaped quote and puts an
   anchor in the middle of an entity, which renders as literal "&" and garbage. */
COURT = {slug: "covid", top: 100, sets: {}};
const quoted = body("Fauci's own words");
ok("an escaped apostrophe is not read as a claim reference",
   quoted === "Fauci&#39;s own words", quoted);
ok("...nor is an escaped ampersand's entity", body("R&D") === "R&amp;D", body("R&D"));

/* NOT EVERY HASH IS A REFERENCE. */
COURT = covid;
ok("a hash inside a word is left alone", body("issue#19") === "issue#19");
ok("a number followed by a word is left alone", body("#19x") === "#19x");
ok("#0 is not a claim — ids are 1-based", body("#0") === "#0");
ok("a hash with no digits is left alone", body("# 19").includes("# 19"));

/* ---- set names ------------------------------------------------------------ */
const F = "\u{13080}", S = "\u{1307C}";
ok("a set named with the shut mark links",
   body("as covered in " + S + " Fauci")
   === 'as covered in <a class="reflink" href="#/c/covid/f/2">' + S + ' Fauci</a>',
   body("as covered in " + S + " Fauci"));
/* WHOLE-STRING, NOT `includes`. The first version of this arm used includes and
   PASSED while the shut arm beside it failed on the identical defect: the two
   marks share a high surrogate, so a character class matched half of one and the
   href still appeared in the output — with the anchor opening inside the glyph.
   An assertion that only asks "is the link in there" cannot see a link in the
   wrong PLACE. */
ok("...and with the open mark, since either may have been filed",
   body(F + " Fauci") === '<a class="reflink" href="#/c/covid/f/2">' + F + ' Fauci</a>',
   body(F + " Fauci"));
/* AND NEITHER MARK IS EVER SPLIT. A lone surrogate is a high one not followed by
   a low, or a low not preceded by a high; the browser draws it as U+FFFD. */
const LONE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/;
for (const t of [F + " Fauci", S + " Fauci", "text " + F + " Fauci text", F + " Origins"])
  ok(`the mark survives whole: ${JSON.stringify(t)}`, !LONE.test(body(t)), JSON.stringify(body(t)));
/* LONGEST FIRST. Matched short-first, "𓁼 Fauci grants" comes out as a link to
   the Fauci set with " grants" dangling after it as text. */
ok("the longer of two overlapping names wins",
   body(S + " Fauci grants").includes('href="#/c/covid/f/7"')
   && !body(S + " Fauci grants").includes('href="#/c/covid/f/2"'));
ok("a name this court does not have stays text",
   body(S + " Origins") === S + " Origins");
ok("a name without a mark in front is not a reference",
   body("Fauci said so") === "Fauci said so");
/* A NAME WITH MARKUP CHARACTERS IN IT, escaped to match escaped text. */
ok("a set name holding an ampersand still matches its escaped form",
   body(S + " Lab & leak").includes('href="#/c/covid/f/9"'), body(S + " Lab & leak"));

/* AND A NAME THAT IS ITSELF A REGULAR EXPRESSION. Set names come off the chain,
   so an unquoted one is a pattern written by whoever filed the set — "a.c" would
   match "abc", and "(x)" would open a capture group that shifts every argument
   the replace callback receives. Quoting is the fix; these are the two arms that
   can tell whether it happened, and an ampersand alone could not. */
COURT = {slug: "covid", top: 30, sets: {"a.c": "1", "Fauci (2020)": "5"}};
ok("a name with a dot in it matches that dot and nothing else",
   body(S + " a.c").includes('href="#/c/covid/f/1"'));
ok("...and does NOT match some other character in that place",
   body(S + " abc") === S + " abc", body(S + " abc"));
ok("a name with brackets matches literally",
   body(S + " Fauci (2020)")
   === '<a class="reflink" href="#/c/covid/f/5">' + S + ' Fauci (2020)</a>',
   body(S + " Fauci (2020)"));
COURT = covid;

/* ---- the two together, and no nesting ------------------------------------- */
COURT = {slug: "covid", top: 30, sets: {"Claim #12 review": "4"}};
const both = body(S + " Claim #12 review and also #19");
ok("a set name containing a hash is not linked twice",
   (both.match(/<a /g) || []).length === 2, both);
ok("...the set's own href wins inside it", both.includes('href="#/c/covid/f/4"'));
ok("...and the reference after it still links", both.includes('href="#/c/covid/19"'));

/* ---- silence -------------------------------------------------------------- */
COURT = null;
ok("a court that was never read links nothing",
   body("see #19 and " + S + " Fauci") === "see #19 and " + S + " Fauci");
COURT = covid;
ok("a DIFFERENT court links nothing — the wrong answer that would look right",
   body("see #19", "orem") === "see #19");
ok("no slug at all links nothing", body("see #19", "") === "see #19");
ok("empty text stays empty", linkRefs("", "covid") === "");

/* ---- and the two surfaces actually print through it ------------------------
   Everything above tests linkRefs in isolation, which says nothing about whether
   a claim body or a comment reaches it — the whole feature can be removed at the
   call site with every assertion here still green. Measured: deleting the call
   in claimBody survived this file until these two arms existed. */
ok("a claim's body links its references",
   /<p>\$\{linkRefs\(esc\(p\), slug\)\}<\/p>/.test(src));
ok("...and so does every comment", /<p>\$\{linkRefs\(esc\(p\), slug\)\.replace\(/.test(src));
/* BOTH TAKE A SLUG RATHER THAN A PREBUILT INDEX. The court's own two lookups are
   the answer, so there is nothing to build and nothing to thread. */
ok("the body takes the court it belongs to", /function claimBody\(d, slug\)\{/.test(src));
ok("...and so does the comment renderer", /function boardText\(s, slug\)\{/.test(src));
ok("...and each caller hands it the slug it is rendering",
   /\+ claimBody\(c, slug\)/.test(src) && /\+ claimBody\(d, slug\)/.test(src)
   && /boardText\(r\.text, slug\)/.test(src));

/* ---- the pattern is chat.js's, and must stay so ---------------------------- */
const chat = require("fs").readFileSync(
  require("path").join(__dirname, "..", "chat.js"), "utf8");
const mine = /const CLAIM_REF_RE = (\/.*\/g);/.exec(src);
const theirs = /const CHATCLAIMREF = (\/.*\/g);/.exec(chat);
ok("both files have a claim-reference pattern", !!mine && !!theirs);
/* THE SAME PATTERN, TWO FILES. chat.js is standalone on purpose — its own
   escaper, no chain reads, loadable alone by its harness — so it is not imported
   from here; and the page does not call ITS renderer, because that link wears a
   class its own stylesheet paints and body text must not depend on whether the
   chat panel mounted. What must not drift is the pattern, so it is compared. */
ok("...and they are the same one, character for character",
   !!mine && !!theirs && mine[1] === theirs[1], `${mine && mine[1]}  vs  ${theirs && theirs[1]}`);

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
