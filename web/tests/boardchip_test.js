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
const { slice } = require("./srcslice");
// esc and shortAddr come from the FILE, not from a local copy: a re-typed
// escaper that is kinder than the real one would let an escaping assertion pass
// against a function the page never calls.
eval(slice('function esc(s){', '\n/* undo the realm'));
eval(slice('function shortAddr(', '\nfunction wall('));
eval(slice('function wireFields(', '\nconst boardNewestRows'));
eval(slice('const boardNewestRows', '\n\n').replace(/^const /gm, 'var '));
// commentCountLabel is the sentence itself; boardChipLabel only decides whether
// there is one. Sliced from the FILE for the same reason esc is — a re-typed
// copy would let these assertions pass against a function the page never calls.
// bcountsParse, bcountsGet, boardCountsOf and commentCountLabel are one run of
// the file, so one slice takes them all. Only the first and last are called
// here; the middle two are defined and never invoked, which costs nothing and
// keeps the boundary at a landmark rather than in the middle of a function.
eval(slice('function bcountsParse(', '\nconst boardWire').replace(/^const /gm, 'var '));
eval(slice('function boardChipLabel(', '\n/* BoardSize FIRST'));

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };
const party = role => ({role});

/* ---- HOW MANY, AND IN HOW MANY CONVERSATIONS --------------------------------
   ROWS ARE THE HEADLINE and threads are the qualifier, which is the call
   board.gno already made and had to FIX once: writeBoardLink counted
   cs.boardTop, so a board with three threads and two replies advertised
   "3 comments" and then showed five things to read. The number in front of a
   discussion is a promise about how much there is to read. */
{
  ok("rows lead, and the threads qualify them",
     commentCountLabel(7, 3) === "7 comments in 3 threads");
  ok("one thread is singular",
     commentCountLabel(5, 1) === "5 comments in 1 thread");

  /* THREADS UNKNOWN IS NOT THREADS ZERO. A realm without BoardCounts cannot
     say, and the label must not invent a fact about the shape of a discussion
     it never asked about — so null prints the count alone. */
  ok("a chain that cannot say prints the count alone",
     commentCountLabel(7, null) === "7 comments");
  ok("...and so does an undefined, which is how the old three-arg callers arrive",
     boardChipLabel(7, true, []) === "7 comments");

  /* A FLAT BOARD IS DESCRIBED, NOT COUNTED. Every comment being its own thread
     is worth saying in words; "3 comments in 3 threads" is arithmetic the
     reader has to do to learn that nobody answered anybody. */
  ok("a board where nothing was replied to says so",
     commentCountLabel(3, 3) === "3 comments, none replied to");
  ok("...and threads can never exceed rows, so that branch covers it too",
     commentCountLabel(3, 9) === "3 comments, none replied to");

  ok("a single comment is trivially one thread, so it says neither",
     commentCountLabel(1, 1) === "1 comment");
  ok("nothing at all for an empty board", commentCountLabel(0, 0) === ""
     && commentCountLabel(-2, 1) === "");
}

/* ---- THE PACKED REPLY, PARSED ------------------------------------------------
   The realm answers `<id>:<rows>:<threads>;…` for many claims at once. The
   FIELD ORDER is the whole risk here: reading rows out of the threads column
   produces a page that is wrong in a plausible way, and a mutant that did
   exactly that survived every harness in this repo until these arms existed. */
{
  const one = bcountsParse("7:9:4")[0];
  ok("rows come from the middle field and threads from the last",
     one.id === "7" && one.rows === 9 && one.threads === 4);

  const many = bcountsParse("7:9:4;8:0:0;12:3:3");
  ok("every record in the reply is read", many.length === 3);
  ok("a quiet claim is a zero pair, not an omission",
     many[1].id === "8" && many[1].rows === 0 && many[1].threads === 0);
  ok("the realm's order is preserved, since a caller matches on the id field",
     many.map(r => r.id).join(",") === "7,8,12");

  /* DROPPED RATHER THAN HALF-READ. A record of the wrong arity means this
     overlay and that realm disagree about the grammar, and guessing which two
     of three fields were meant is how a wrong number reaches a reader. */
  ok("a record of the wrong arity is dropped", bcountsParse("7:9").length === 0
     && bcountsParse("7:9:4:1").length === 0);
  ok("a non-numeric count is dropped rather than becoming NaN in a sentence",
     bcountsParse("7:x:4").length === 0 && bcountsParse("7:9:y").length === 0);
  ok("an empty reply is no records, not one broken one",
     bcountsParse("").length === 0 && bcountsParse(null).length === 0);
}

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
    /* AND THE SAMPLE MAP'S THREAD COUNT IS THAT SAME LINE COUNT, which is how
       boardCountsPreload derives it with no chain to ask. Tied to the assertion
       just above — size is top-level rows plus their replies — so threads is
       rows.length and can never exceed size. Without this the demo map could
       draw a hover sentence no fixture backs. */
    ok(b.name+": the thread count the sample map draws is its top-level rows",
       rows.length > 0 && rows.length <= b.size
       && commentCountLabel(b.size, rows.length) === (rows.length >= b.size
            ? b.size + " comments, none replied to"
            : b.size + " comments in " + rows.length + " thread" + (rows.length===1?"":"s")));
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
