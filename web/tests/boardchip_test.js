#!/usr/bin/env node
// THE CLAIM PAGE'S BOARD CHIP — the one line that decides whether anybody opens
// the board at all — plus the sample board data behind it.
//
// Two things are tested here and they are different in kind:
//
//   1. boardChipLabel, a pure function. Every branch, including the two that
//      render NOTHING, because "no chip" is a decision and not an absence.
//   2. The DEMO board fixtures, checked against their own declared size. The
//      sample carries wire strings and a count, and nothing but this test makes
//      them agree — the first draft of orem/2 declared 5 rows and contained 4.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'index.html'), 'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
// esc and shortAddr come from the FILE, not from a local copy: a re-typed
// escaper that is kinder than the real one would let an escaping assertion pass
// against a function the page never calls.
eval(slice('function esc(s){', '\n/* undo the realm'));
eval(slice('function shortAddr(', '\nfunction wall('));
eval(slice('function wireFields(', '\nconst boardNewestRows'));
eval(slice('const boardNewestRows', '\n\n').replace(/^const /gm, 'var '));
eval(slice('function boardChipLabel(', '\n/* BoardSize FIRST'));

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };
const party = role => ({role});

// ---- the empty board: an invitation, or silence ---------------------------
// The realm makes the same call on its own page (board.gno writeBoardLink): an
// empty board is worth an invitation only while somebody can still accept one.
{
  ok("an open board with no comments invites the first",
     boardChipLabel(0, true, []) === "discuss this claim");
  ok("a CLOSED board with no comments says nothing at all",
     boardChipLabel(0, false, []) === "");
  ok("...and renders no element, not an empty link",
     boardChip("covid", 3, 0, false, []) === "");
  ok("the invitation is a real link to the board route",
     /href="#\/c\/covid\/3\/board"/.test(boardChip("covid", 3, 0, true, [])));
}

// ---- the count, whoever spoke ---------------------------------------------
// It used to lead with who had replied — "the author and the answerer have
// replied · 5 comments" — on the argument that a fact beats a number. The owner
// asked for it gone: in a row where every neighbour is one word, it was a
// sentence. What must NOT come back is the party prefix; the parties are on the
// board, and the chip says there is something there and how much.
{
  const party = r => ({role: r});
  ok("both parties still get the plain count",
     boardChipLabel(5, true, [party("author"), party("answerer")]) === "5 comments");
  ok("the author alone", boardChipLabel(5, true, [party("author")]) === "5 comments");
  ok("the answerer alone", boardChipLabel(5, true, [party("answerer")]) === "5 comments");
  ok("neither party", boardChipLabel(5, true, []) === "5 comments");
  ok("an unrecognised role changes nothing",
     boardChipLabel(5, true, [party("moderator")]) === "5 comments");
  ok("no label mentions a party any more",
     ![[party("author")], [party("answerer")], [party("author"), party("answerer")]]
       .some(ps => /replied|author|answerer/.test(boardChipLabel(5, true, ps))));
}

// ---- one label for the count ---------------------------------------------
{
  ok("one comment is singular", boardChipLabel(1, true, []) === "1 comment");
  ok("and plural above one", boardChipLabel(2, true, []) === "2 comments");
  ok("an empty board that is still open invites",
     boardChipLabel(0, true, []) === "discuss this claim");
  ok("and a settled one with nothing on it says nothing",
     boardChipLabel(0, false, []) === "");
}

// ---- the sample boards ----------------------------------------------------
// size is what BoardSize returns: EVERY row, replies included. The fixtures
// carry it separately from the rows, so only this check keeps them honest.
{
  const grab = (re, cut) => { const m = src.match(re); return m ? m[0].slice(cut, -1).replace(/\\n/g, "\n") : null; };
  // READ THE DECLARED SIZE OUT OF index.html, do not restate it here. Written
  // the obvious way — `{name:"orem/2", size:4, …}` in this table — the check
  // compares the test's own constant against the rows and holds nothing: an
  // ablation that changed the sample from 4 to 5 passed. The number under test
  // has to come from the file under test.
  const sizeBefore = re => {
    const i = src.search(re); if(i < 0) return NaN;
    const j = src.lastIndexOf("board:{ size:", i);
    return j < 0 ? NaN : parseInt(src.slice(j + "board:{ size:".length), 10);
  };
  const P1 = /parties:"7\|g1oremfiler[^"]*"/, P2 = /parties:"12\|g1oremfiler[^"]*"/;
  const boards = [
    {name:"orem/1", size:sizeBefore(P1),
     newest: grab(/newest:"9\|g1clerkwatch[^"]*"/, 8),
     parties:grab(P1, 9), roles:["author"]},
    {name:"orem/2", size:sizeBefore(P2),
     newest: grab(/newest:"13\|g1rangewatch[^"]*"/, 8),
     parties:grab(P2, 9), roles:["author","answerer"]},
  ];
  for(const b of boards){
    ok(b.name+": the sample wire is present in index.html", !!b.newest && !!b.parties);
    ok(b.name+": its declared size was actually found in the source", isFinite(b.size));
    const rows = boardNewestRows(b.newest || "");
    const total = rows.length + rows.reduce((a, r) => a + parseInt(r.replies, 10), 0);
    // The declared size must be derivable from the rows, or the chip advertises
    // a number the board page cannot show.
    ok(b.name+": declared size equals top-level rows plus their replies",
       total === b.size);
    ok(b.name+": every row parses at the Newest arity", rows.length > 0 && rows.every(r => isFinite(r.id) && r.author));
    ok(b.name+": every row carries a plausible block height",
       rows.every(r => isFinite(r.at) && r.at > 0));
    const ps = boardPartyRows(b.parties || "");
    ok(b.name+": the party roles are the ones this claim should have",
       ps.map(r => r.role).join(",") === b.roles.join(","));
    // A party row must name a row that is actually on the board, or the chip
    // claims a reply the page will not show.
    const ids = new Set(rows.map(r => r.id));
    ok(b.name+": every party row is a top-level row on the same board",
       ps.every(r => ids.has(r.id)));
  }
  // orem/2 carries a hidden row on purpose: a tombstone still counts toward the
  // size the chip advertises, because it occupies a line on the page.
  const two = boardNewestRows(boards[1].newest);
  ok("orem/2 keeps a withheld row, with a mark and no text",
     two.some(r => r.mark === "h" && r.text === ""));
}

// ---- the wiring -----------------------------------------------------------
// A pure function with no caller is the failure this feature has already had
// TWICE: the wire parser shipped unused in two separate commits before anything
// called it. There is no DOM here, so the three links in the chain are checked
// as text — slot, filler, call site.
{
  ok("the tagrow carries a slot for the chip",
     /<span id="boardchip"><\/span>/.test(src));
  ok("fillBoardChip writes into that slot",
     /getElementById\("boardchip"\)/.test(src));
  ok("...and the claim route calls it",
     /^\s*fillBoardChip\(slug, ?id\);/m.test(src));
}

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
