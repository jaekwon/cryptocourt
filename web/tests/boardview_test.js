#!/usr/bin/env node
// THE BOARD PAGE'S RENDERERS — the surface where 2000 bytes of stranger-written
// text becomes HTML.
//
// board_test.gno asserts the realm does NOT sanitise on the wire: sanitising
// belongs to whoever renders, and this is the whoever. So the first question of
// every assertion below is "what does a hostile author get to put in the DOM",
// and the second is whether the page tells the truth about rows it cannot show.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'index.html'), 'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
// The helpers the renderers lean on, taken from the file rather than restated —
// a local copy of esc() that is kinder than the real one would prove nothing.
eval(slice('function esc(s){', '\n/* undo the realm'));
eval(slice('function shortAddr(', '\nfunction wall('));
eval(slice('function fmtN(', '\n').replace(/^function /, 'function '));
const CFG = {gnoweb:"https://gnoweb.example.test/"};
// `const` inside eval() is block-scoped to the eval and does not reach this
// file; `function` declarations do. BOARD_TOMB, gnowebRow and the two meta
// helpers are consts, so they need the same rewrite the other harnesses use.
eval(slice('function boardText(', '\non(/^\\/c\\/').replace(/^const /gm, 'var '));

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };
const row = o => Object.assign({id:5, author:"g1abcdefghijklmnop", mark:".", at:4799200,
                                text:"a comment", replies:"0", score:"0"}, o);

// ---- text is escaped, never interpreted -----------------------------------
{
  const evil = boardText('<img src=x onerror="alert(1)"> & `tick` \'q\'');
  ok("angle brackets never reach the DOM as markup", !/<img/.test(evil));
  ok("the ampersand is entity-encoded", evil.includes("&amp;"));
  ok("quotes and backticks are encoded too",
     evil.includes("&#39;") && evil.includes("&#96;"));
  // NOT markdown. The realm sanitises for ITS renderer; re-reading the same text
  // as markup here would be a second attack surface on the same field.
  const md = boardText("[click](javascript:alert(1)) **bold**");
  ok("markdown is left as characters, not turned into markup",
     !/<a /.test(md) && !/<strong>/.test(md) && md.includes("**bold**"));
}

// ---- the shape of a comment ----------------------------------------------
{
  const two = boardText("first para\n\nsecond para");
  ok("a blank line starts a new paragraph", (two.match(/<p>/g)||[]).length === 2);
  const br = boardText("line one\nline two");
  ok("a single newline is a break inside one paragraph",
     (br.match(/<p>/g)||[]).length === 1 && br.includes("<br>"));
  ok("empty text says so rather than rendering nothing",
     boardText("").includes("(empty)") && boardText(null).includes("(empty)"));
  ok("whitespace-only text is empty too", boardText("   \n\n  ").includes("(empty)"));
}

// ---- tombstones -----------------------------------------------------------
// The three marks, and what this surface is allowed to say about each.
{
  const h = boardRowHtml("covid", 3, row({mark:"h", text:""}), "", "");
  ok("a hidden row renders its tombstone", h.includes("Hidden from this list"));
  // `h` is the DISJUNCTION of hiddenByAuthor and hiddenByMod. The wire does not
  // say which, so neither may this page: "withdrawn by its author" over a
  // moderator's act is false about a person half the time.
  ok("...and names no actor", !/author|moderator|withdrawn/i.test(h));
  // A hide is a DISCOVERY bit — the row still reads at its own route — so copy
  // that says "it still reads at its own link" has to carry one.
  ok("...and the link it promises actually exists",
     h.includes("/r/kourt/kourtv2:covid/3/board/5") && h.includes("read it"));

  const g = boardRowHtml("covid", 3, row({mark:"g", text:""}), "", "");
  ok("a globally withheld row uses the realm's own sentence",
     g.includes("Withheld pending a legal determination."));
  const x = boardRowHtml("covid", 3, row({mark:"x", text:""}), "", "");
  ok("a purged row uses the realm's own sentence",
     x.includes("Removed. The text is gone from the record; the row remains."));
  // g and x are NOT reachable, so they get no "read it" link — offering one
  // would send a reader to a page that withholds the same thing.
  ok("neither g nor x offers a link to text that is not there",
     !g.includes("read it") && !x.includes("read it"));

  // A tombstone must not carry the text the realm withheld. The realm packs an
  // empty text for a marked row, but a client that trusted `text` over `mark`
  // would print whatever arrived.
  const forged = boardRowHtml("covid", 3, row({mark:"h", text:"the withheld sentence"}), "", "");
  ok("a marked row shows its tombstone, not any text that came with it",
     !forged.includes("the withheld sentence"));
}

// ---- the row's citation line ---------------------------------------------
{
  const r = boardRowHtml("covid", 3, row({at:88560}), "2 replies", "author");
  ok("the row is dated with the block it landed in", r.includes("block 88560"));
  ok("the row links to itself by id", r.includes(">#5</a>"));
  ok("the ordering's own field is rendered as what it is", r.includes("2 replies"));
  ok("a party is badged", /class="pill">author</.test(r));
  const plain = boardRowHtml("covid", 3, row(), "", "");
  ok("a row with no role gets no empty pill", !plain.includes('class="pill"'));
  // The author string is chain data on a page anyone can link to.
  const nasty = boardRowHtml("covid", 3, row({author:'g1<script>x</script>'}), "", "");
  ok("the author is escaped like everything else", !nasty.includes("<script>"));
}

// ---- the reply cap, told rather than hidden -------------------------------
// The realm serves at most 8 replies per parent while the parent's count is the
// true one, so a capped thread would otherwise read as complete.
{
  const parent = row({id:5, replies:"14"});
  const eight = Array.from({length:8}, (_,i) => row({id:100+i}));
  const out = boardRepliesHtml("covid", 3, parent, eight);
  ok("a capped thread says how much it is not showing", out.includes("8 of 14 replies shown"));
  ok("...and points at where the rest are", out.includes("/board/5"));

  const three = Array.from({length:3}, (_,i) => row({id:200+i}));
  const full = boardRepliesHtml("covid", 3, row({id:5, replies:"3"}), three);
  ok("an uncapped thread says nothing about a cap", !full.includes("shown"));
  ok("no replies renders nothing at all",
     boardRepliesHtml("covid", 3, parent, []) === ""
     && boardRepliesHtml("covid", 3, parent, null) === "");
}

// ---- the state line -------------------------------------------------------
{
  ok("an open board says so", boardStateLine(5, true) === "5 comments · open for comments");
  ok("a closed board names the reason",
     boardStateLine(5, false) === "5 comments · closed — this claim has a verdict");
  ok("one comment is singular", boardStateLine(1, true).startsWith("1 comment ·"));
}

// ---- what each ordering knows --------------------------------------------
{
  ok("Newest shows a reply count only when there are replies",
     boardMetaNewest(row({replies:"3"})) === "3 replies" && boardMetaNewest(row({replies:"0"})) === "");
  ok("...and it is singular at one", boardMetaNewest(row({replies:"1"})) === "1 reply");
  ok("Top shows a score only when it is nonzero",
     boardMetaTop(row({score:"4712"})).startsWith("score") && boardMetaTop(row({score:"0"})) === "");
}

// ---- the routes exist -----------------------------------------------------
// The claim page's chip has linked here since before this page did; a chip
// pointing at "No such page" is the defect these two lines prevent.
{
  ok("the board route is registered", src.includes("\\/board$/,"));
  ok("the ranked route is registered", src.includes("\\/board\\/top$/,"));
  ok("both are wired to boardView, one ranked and one not",
     /boardView\(slug, ?id, ?false\)/.test(src) && /boardView\(slug, ?id, ?true\)/.test(src));
  ok("the chip links at the route that exists",
     src.includes('href="#/c/${esc(slug)}/${id}/board"'));
}

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
