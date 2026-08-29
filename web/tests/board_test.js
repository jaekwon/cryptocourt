#!/usr/bin/env node
// THE COMMENT BOARD'S WIRE, tested against what a hostile author can write.
//
// This layer is the whole risk surface of the board feature. Comment text is
// attacker-controlled, up to 2000 bytes, and board_test.gno asserts the realm
// must NOT sanitise it on the wire — sanitising belongs to the realm's own
// render path. So everything here is about surviving text that was chosen to
// break a parser: pipes, newlines, forged escapes, and bytes that Go's quoting
// escapes in a form JSON refuses.
//
// Three of the four cases below were found by reading board.gno rather than by
// imagination, and each one silently corrupts a page rather than failing loudly:
// a truncated split eats the end of a sentence, a naive unescape re-forges an
// escape the realm made unforgeable, and a JSON.parse fallback turns one bad
// comment into a whole board of garbage.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'index.html'), 'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
eval(slice('function wireFields(', '\nconst boardNewestRows'));
eval(slice('const boardNewestRows', '\n\n').replace(/^const /gm, 'var '));

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// ---- pipes in text -------------------------------------------------------
// JS `split("|", 5)` TRUNCATES where Go's SplitN joins the remainder. Measured:
// "a|b|c|d|e | f".split("|",5) drops everything after the pipe in the text.
{
  const r = boardNewestRows('7|g1abc|3|.|the ratio is 4|3 by their own table')[0];
  ok("text keeps every pipe it contained", r.text === "the ratio is 4|3 by their own table");
  ok("...and the fields before it are still right",
     r.id === 7 && r.author === "g1abc" && r.replies === "3" && r.mark === ".");
}

// ---- the three packings are not interchangeable --------------------------
{
  // Guarded, because the failure mode being tested is a parser that returns NO
  // rows: an unguarded rep.mark throws and takes the harness down, which reads
  // as "no assertion fired" rather than as the defect it is.
  const rep = boardReplyRows('9|g1xyz|h|withheld text here')[0] || {};
  ok("a reply line parses at all under the 4-field read", rep.id === 9);
  ok("a reply's 3rd field is its MARK, not a reply count", rep.mark === "h");
  ok("...and its text is the 4th field", rep.text === "withheld text here");
  const top = boardTopRows('4|g1abc|4712|.|ranked row')[0];
  ok("a Top row's 3rd field is its SCORE", top.score === "4712");
  // The same line read with the wrong arity is exactly the bug this prevents.
  const wrong = boardNewestRows('9|g1xyz|h|withheld text here');
  ok("a 4-field line refuses a 5-field read rather than mis-parsing", wrong.length === 0);
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
  const rows = boardNewestRows('5|g1abc|0|h|\n6|g1def|0|.|still here');
  ok("a hidden row survives with empty text", rows.length === 2 && rows[0].mark === "h" && rows[0].text === "");
  ok("...and the row after it is unaffected", rows[1].text === "still here");
}

// ---- junk ---------------------------------------------------------------
{
  ok("empty input is no rows", boardNewestRows("").length === 0);
  ok("a short line is dropped, not guessed at", boardNewestRows("1|g1abc").length === 0);
  ok("blank lines between rows are ignored",
     boardNewestRows('1|a|0|.|x\n\n2|b|0|.|y').length === 2);
}

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
