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

// ---- the fact, not the count ---------------------------------------------
// "5 comments" does not tell a reader whether it is worth opening. Who replied
// does, and the count is then the size of what is behind the link.
{
  ok("both parties",
     boardChipLabel(5, true, [party("author"), party("answerer")])
     === "the author and the answerer have replied · 5 comments");
  ok("the author alone",
     boardChipLabel(5, true, [party("author")]) === "the author has replied · 5 comments");
  // NOT the same string with a word removed: the realm returns ONE party row
  // when only one party has commented and it may be either of them, so this
  // branch is reachable without the author's.
  ok("the answerer alone",
     boardChipLabel(5, true, [party("answerer")]) === "the answerer has replied · 5 comments");
  ok("neither party — the count stands on its own",
     boardChipLabel(5, true, []) === "5 comments");
  ok("an unrecognised role is not silently read as a party",
     boardChipLabel(5, true, [party("moderator")]) === "5 comments");
}

// ---- one label for the count ---------------------------------------------
// An earlier draft said "5 comments" beside a party line and "5 comments and
// replies" without one — one number described two ways reads as two numbers.
{
  const withParty = boardChipLabel(5, true, [party("author")]);
  const without   = boardChipLabel(5, true, []);
  ok("the count is phrased identically on both branches",
     withParty.endsWith(without));
  ok("one comment is singular", boardChipLabel(1, true, []) === "1 comment");
  ok("...on the party branch too",
     boardChipLabel(1, true, [party("author")]) === "the author has replied · 1 comment");
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

// ---- the parties' own words ----------------------------------------------
// The chip says THAT they replied; this says WHAT they said. It renders from the
// rows fillBoardChip has already fetched, so it costs no read.
{
  eval(slice('const BOARD_TOMB = {', '\nconst gnowebRow').replace(/^const /gm, 'var '));
  eval(slice('const clipText =', '\nasync function fillBoardChip').replace(/^const /gm, 'var '));
  const P = (role, text, o) => Object.assign({id:7, author:"g1abcdefghijklmnop", role, mark:".",
                                              at:4799200, text}, o||{});
  const two = boardPreviewHtml("covid", 3, [P("author","The 12,412 figure is the certified count."),
                                            P("answerer","It is the denominator the WHO published.", {id:8})]);
  ok("both parties are previewed", (two.match(/bpreview-row/g)||[]).length === 2);
  ok("...each named by role, which is what makes them an argument",
     /class="pill">author</.test(two) && /class="pill">answerer</.test(two));
  ok("...and each links to the board", (two.match(/#\/c\/covid\/3\/board/g)||[]).length === 2);

  // A withheld row has nothing to preview. The board page still lists it, marked.
  const held = boardPreviewHtml("covid", 3, [P("author","", {mark:"h"}), P("answerer","said something", {id:8})]);
  ok("a withheld party row is skipped, not previewed as a tombstone",
     (held.match(/bpreview-row/g)||[]).length === 1 && held.includes("said something"));
  ok("no showable rows renders nothing at all",
     boardPreviewHtml("covid", 3, [P("author","", {mark:"x"})]) === ""
     && boardPreviewHtml("covid", 3, []) === "");

  // Long text is clipped to one line, and the clipping is on a copy.
  const long = "x".repeat(400);
  const clipped = boardPreviewHtml("covid", 3, [P("author", long)]);
  ok("a long comment is clipped rather than pasted whole",
     clipped.includes("…") && clipped.length < long.length);
  ok("newlines are flattened, so a multi-line comment stays one line",
     clipText("a\n\nb   c") === "a b c");
  // Text is chain data on a page anyone can link to.
  ok("the preview escapes like everything else",
     !boardPreviewHtml("covid", 3, [P("author", "<img src=x>")]).includes("<img src=x"));
}

// ---- the wiring -----------------------------------------------------------
// A pure function with no caller is the failure this feature has already had
// TWICE: the wire parser shipped unused in two separate commits before anything
// called it. There is no DOM here, so the three links in the chain are checked
// as text — slot, filler, call site.
{
  ok("the tagrow carries a slot for the chip",
     /<span id="boardchip"><\/span>/.test(src));
  // The preview needs its own two links checked, and separately: deleting either
  // the slot or the fill leaves the other in place and passed until these lines
  // existed. Every pure function in this file had a caller; neither wiring
  // assertion existed to say so.
  ok("the claim page carries a slot for the parties' preview",
     /<div id="boardpreview"><\/div>/.test(src));
  ok("...and fillBoardChip fills it from the rows it already has",
     /if\(pv\) pv\.innerHTML = boardPreviewHtml\(slug, id, parties\);/.test(src));
  // Scoped to fillBoardChip, not the whole file: boardView fetches the party
  // rows too, for its in-place badges, so a file-wide count is 2 and says
  // nothing about whether the preview added a read.
  ok("...fetched ONCE and used twice, so the preview costs no extra read",
     (slice('async function fillBoardChip', '\n}\n')
        .match(/await boardParties\(slug, id\)/g) || []).length === 1);
  ok("fillBoardChip writes into that slot",
     /getElementById\("boardchip"\)/.test(src));
  ok("...and the claim route calls it",
     /^\s*fillBoardChip\(slug, ?id\);/m.test(src));
}

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
