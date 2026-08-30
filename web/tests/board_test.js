#!/usr/bin/env node
// THE COMMENT BOARD'S WIRE, tested against what a hostile author can write.
//
// This layer is the whole risk surface of the board feature. Comment text is
// attacker-controlled, up to 2000 characters, and board_test.gno asserts the realm
// must NOT sanitise it on the wire — sanitising belongs to the realm's own
// render path. So everything here is about surviving text that was chosen to
// break a parser: pipes, newlines, forged escapes, and bytes that Go's quoting
// escapes in a form JSON refuses.
//
// The hazards here were found by reading board.gno rather than by imagination,
// and every one silently corrupts a page rather than failing loudly: a truncated
// split eats the end of a sentence, a naive unescape re-forges an escape the
// realm made unforgeable, a line read at the wrong arity welds a block height
// onto the front of somebody's argument, and a JSON.parse fallback turns one bad
// comment into a whole board of garbage.
//
// The last two blocks test the READ path — boardUnwrap and the four readers —
// and the parseTyped case is written as a comparison rather than an assertion:
// it runs the shipped alternative against the same input and shows it collapsing
// the board, so the defence is measured against what it replaced.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'index.html'), 'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
eval(slice('function wireFields(', '\nconst boardNewestRows'));
eval(slice('const boardNewestRows', '\n\n').replace(/^const /gm, 'var '));
// parseTyped is pulled in NOT to test it but to demonstrate against it: the last
// block below shows what the board would read if it went through one().
eval(slice('function parseTyped(', '\nconst one ='));
// The readers, with the RPC stubbed. Declaring these before the eval so the
// arrow functions it defines can close over them.
let LASTEXPR = null, QREPLY = '';
const qeval = async e => { LASTEXPR = e; return QREPLY; };
const gstr  = s => JSON.stringify(String(s));
eval(slice('const boardWire', '\n\n/* =').replace(/^const /gm, 'var '));

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// ---- pipes in text -------------------------------------------------------
// JS `split("|", 5)` TRUNCATES where Go's SplitN joins the remainder. Measured:
// "a|b|c|d|e | f".split("|",5) drops everything after the pipe in the text.
{
  const r = boardNewestRows('7|g1abc|3|.|88560|the ratio is 4|3 by their own table')[0];
  ok("text keeps every pipe it contained", r.text === "the ratio is 4|3 by their own table");
  ok("...and the fields before it are still right",
     r.id === 7 && r.author === "g1abc" && r.replies === "3" && r.mark === ".");
  // `at` is a NUMBER, not the string the wire carried: it is arithmetic on the
  // render path ("N blocks ago"), and "88560" - 1 is not.
  ok("the block height parses as a number", r.at === 88560);
}

// ---- the three packings are not interchangeable --------------------------
{
  // Guarded, because the failure mode being tested is a parser that returns NO
  // rows: an unguarded rep.mark throws and takes the harness down, which reads
  // as "no assertion fired" rather than as the defect it is.
  const rep = boardReplyRows('9|g1xyz|h|4102|withheld text here')[0] || {};
  ok("a reply line parses at all under the 5-field read", rep.id === 9);
  ok("a reply's 3rd field is its MARK, not a reply count", rep.mark === "h");
  ok("...and its height is the 4th, one field left of where the others put it", rep.at === 4102);
  ok("...and its text is the 5th field", rep.text === "withheld text here");
  const top = boardTopRows('4|g1abc|4712|.|91|ranked row')[0];
  ok("a Top row's 3rd field is its SCORE", top.score === "4712");
  // The score alone does NOT hold this arity: at 5 fields it still reads "4712"
  // and field 5 quietly becomes "91|ranked row". Measured — the ablation that
  // reverts boardTopRows to 5 passed until these two lines existed. Every
  // ordering needs an assertion PAST the field that distinguishes it.
  ok("...its height is the 5th field", top.at === 91);
  ok("...and its text the 6th", top.text === "ranked row");
  const party = boardPartyRows('4|g1abc|answerer|.|91|the denominator the WHO published')[0];
  ok("a party row's 3rd field is its ROLE", party.role === "answerer");
  // The role is READ, never inferred from position: the realm returns one row
  // when only one party has commented, and it may be either of them.
  ok("...spelled out, so a lone row is not assumed to be the author's",
     party.role !== "author" && party.text === "the denominator the WHO published");
  // The same line read with the wrong arity is exactly the bug this prevents.
  const wrong = boardNewestRows('9|g1xyz|h|4102|withheld text here');
  ok("a 5-field line refuses a 6-field read rather than mis-parsing", wrong.length === 0);
}

// ---- forged escapes ------------------------------------------------------
// escapeWireText escapes the BACKSLASH FIRST so an author cannot forge a
// newline. An author who types the two characters \ and n gets \\n on the wire.
{
  ok("a real newline decodes to a newline", unwire("line one\\nline two") === "line one\nline two");
  ok("a typed backslash-n stays two characters, not a newline",
     unwire("literal \\\\n here") === "literal \\n here");
  ok("a lone trailing backslash does not eat the terminator",
     unwire("ends with \\\\") === "ends with \\");
  ok("carriage returns decode too", unwire("a\\rb") === "a\rb");
}

// ---- Go quoting that JSON refuses ---------------------------------------
// strconv.Quote emits \a, \v and \xNN; JSON.parse throws on all three, and
// parseTyped's fallback is raw.slice(1,-1) — every escape left literal,
// INCLUDING the \n that separates rows. One such comment would collapse the
// whole board into one garbage row for every reader.
{
  const raw = '"row one\\ntwo\\x07bell"';
  ok("JSON.parse alone cannot read it", (()=>{ try{ JSON.parse(raw); return false; }catch(_){ return true; } })());
  const out = goUnquote(raw);
  ok("goUnquote recovers the row separator", out.split("\n").length === 2);
  ok("...and the bell byte", out.includes("\x07"));
  ok("a plain JSON string still goes through JSON.parse", goUnquote('"ordinary text"') === "ordinary text");
  ok("an unquoted body is returned as-is", goUnquote('not quoted') === "not quoted");
}

// ---- rows that are meant to be empty -------------------------------------
// The realm returns a hidden row with EMPTY text and a mark, rather than
// dropping it, so the list stays stable. The parser must keep the row.
{
  const rows = boardNewestRows('5|g1abc|0|h|770|\n6|g1def|0|.|771|still here');
  ok("a hidden row survives with empty text", rows.length === 2 && rows[0].mark === "h" && rows[0].text === "");
  ok("...and is still dated, so a tombstone can say when it was written", rows[0].at === 770);
  ok("...and the row after it is unaffected", rows[1].text === "still here");
  // A party row can be a tombstone too — the realm does not filter the reserved
  // slot on its mark, so the client must be able to tell badge-over-nothing from
  // a row with something to say.
  const ph = boardPartyRows('5|g1abc|author|h|770|')[0];
  ok("a withdrawn party row keeps its role and arity", ph && ph.role === "author" && ph.text === "");
}

// ---- junk ---------------------------------------------------------------
{
  ok("empty input is no rows", boardNewestRows("").length === 0);
  ok("a short line is dropped, not guessed at", boardNewestRows("1|g1abc").length === 0);
  ok("blank lines between rows are ignored",
     boardNewestRows('1|a|0|.|9|x\n\n2|b|0|.|10|y').length === 2);
}

// ---- the typed wrapper, and the path it exists to avoid -------------------
// qeval answers `("…" string)`. parseTyped's fallback for a body JSON refuses is
// raw.slice(1,-1) — every escape LEFT LITERAL, including the \n between rows.
// This is not a degraded read, it is a wrong one, and it is reachable by writing
// a comment: strconv.Quote emits \x07 for a byte JSON will not take.
{
  const hostile = '("5|g1a|0|.|77|bell\\x07here\\n6|g1b|0|.|78|second row" string)';
  ok("the wrapper is removed and the body decoded",
     boardUnwrap('("hello" string)') === "hello");
  ok("an empty result is an empty string, not the word undefined",
     boardUnwrap("") === "" && boardUnwrap(null) === "");
  // MEASURED AGAINST THE REAL ALTERNATIVE, not asserted about it.
  ok("parseTyped would collapse this board into ONE row",
     parseTyped(hostile)[0].split("\n").length === 1);
  ok("boardUnwrap recovers both rows", boardUnwrap(hostile).split("\n").length === 2);
  ok("...and the bell byte survives as a byte", boardUnwrap(hostile).includes("\x07"));
  const rows = boardNewestRows(boardUnwrap(hostile));
  ok("...so both rows parse, with the right authors",
     rows.length === 2 && rows[0].author === "g1a" && rows[1].author === "g1b");
}

// ---- the readers ----------------------------------------------------------
(async () => {
  // Each reader quotes its OWN slug. A court slug arrives in the URL, so a slug
  // carrying a quote must become a gno string literal, never an expression.
  QREPLY = '("9|g1xyz|h|4102|withheld" string)';
  const reps = await readBoardReplies('cov"id', 7, 3);
  ok("readBoardReplies quotes the slug it was handed",
     LASTEXPR === 'BoardReplies("cov\\"id",7,3)');
  ok("...and reads it at the 5-field arity", reps.length === 1 && reps[0].mark === "h" && reps[0].at === 4102);

  QREPLY = '("4|g1abc|answerer|.|91|the denominator the WHO published" string)';
  const parties = await readBoardParties("covid", 7);
  ok("readBoardParties names the realm read", LASTEXPR === 'BoardPartyRows("covid",7)');
  ok("...and returns a ROLE, not a reply count", parties[0].role === "answerer");

  QREPLY = '("7|g1abc|3|.|88560|the ratio is 4|3 by their own table" string)';
  // DISTINCTIVE offset and count on purpose. With 0 and 25 this assertion
  // survived an ablation that hardcoded `,0,25)` — the fixture's arguments
  // happened to BE the mutant's constants, so paging looked held and was not.
  const newest = await readBoardNewest("covid", 7, 50, 3);
  ok("readBoardNewest passes offset and count through",
     LASTEXPR === 'BoardNewest("covid",7,50,3)');
  ok("...and the pipe in the text still survives the round trip",
     newest[0].text === "the ratio is 4|3 by their own table");

  QREPLY = '("4|g1abc|4712|.|91|ranked row" string)';
  const top = await readBoardTop("covid", 7, 50, 3);
  ok("readBoardTop reads field 3 as a score", LASTEXPR === 'BoardTop("covid",7,50,3)' && top[0].score === "4712");

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
