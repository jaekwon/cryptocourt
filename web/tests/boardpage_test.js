#!/usr/bin/env node
// THE BOARD PAGE, ASSEMBLED — boardView run end to end against the sample data,
// not its renderers checked one at a time.
//
// boardview_test.js holds the pure functions; this one holds the thing they add
// up to. The difference matters: every renderer can be right while the view
// fetches the wrong ordering, badges nobody, or paints an empty page. There is
// no DOM here, so index.html is evaluated in slices and `main` is a plain object
// with an innerHTML setter — which is all boardView ever touches.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'index.html'), 'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing end "+to);
  return src.slice(a, b);
}
// `const` inside eval is block-scoped to the eval; `function` is not.
const V = s => s.replace(/^const /gm, 'var ');

eval(slice('function esc(s){', '\n/* undo the realm'));
eval(slice('function unesc(', '\n'));
eval(slice('function safeInline(', "\n/* THE CLAIM'S OWN"));
eval(slice('function shortAddr(', '\nfunction wall('));
eval(slice('function fmtN(', '\n'));
eval(slice('function notFound(', '\n'));
var store = {get:()=>null, set:()=>{}};
var location = {hash:"#/c/orem/1/board"};
// courtCrumb first: crumbs' court entries are built through it now.
eval(V(slice('const courtCrumb = (slug, name) =>', '\n};') + '\n};'));
eval(V(slice('const crumbs = parts =>', '\n};') + '\n};'));
eval(slice('function wireFields(', '\nconst boardNewestRows'));
eval(V(slice('const boardNewestRows', '\n\n')));
eval(V(slice('const NOW = 4_800_000', '\nconst DEMO_ME')));

var CFG = {gnoweb:"https://gnoweb.example.test", mode:"demo"};
function isLive(){ return false; }                       // the sample, never a node
eval(V(slice('const demoBoard = (slug, id)', '\n/* ============================ demo dataset')));
eval(V(slice('function boardText(', '\non(/^\\/c\\/')));

var painted = "";
var main = { set innerHTML(v){ painted = v; }, get innerHTML(){ return painted; } };
const count = re => (painted.match(re) || []).length;

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

(async () => {
  // ---- the sample is actually there ---------------------------------------
  // If this fails, every assertion below is testing an empty page and passing
  // for the wrong reason.
  ok("the sample carries boards on both specimen claims",
     !!DEMO.claims["orem/1"].board && !!DEMO.claims["orem/2"].board);

  // ---- orem/1: three comments, one reply, only the author has spoken -------
  await boardView("orem", "1", false);
  ok("orem/1 paints every row the board holds", count(/class="boardrow"/g) === 4);
  ok("...including the reply, indented under its parent", count(/class="boardkids"/g) === 1);
  ok("...and badges the author in place", /class="pill">author</.test(painted));
  ok("...but not an answerer, who has not commented", !/class="pill">answerer</.test(painted));
  ok("the state line agrees with BoardSize", painted.includes("4 comments · open for comments"));
  ok("the page names the claim it belongs to", painted.includes("12,412 mail ballots"));
  ok("...and links back to it", painted.includes('href="#/c/orem/1"'));
  // The reply count in the meta line is the ordering's own field. A parent with
  // one reply and a parent with none must not read the same.
  ok("a parent with replies says so, a parent without says nothing",
     painted.includes("1 reply") && !painted.includes("0 replies"));
  // Nothing is capped here, so nothing may claim to be.
  ok("an uncapped board mentions no cap", !/of \d+ (replies )?shown/.test(painted));

  // ---- orem/2: both parties, a tombstone, and a real ranking ---------------
  await boardView("orem", "2", false);
  // THREE, not four: the sample's hidden row is dropped from the draw rather
  // than stubbed. The wire still carries it — boardview_test holds that — and
  // the header's count is what tells a reader it exists.
  ok("orem/2 paints only the rows it can show", count(/class="boardrow"/g) === 3);
  ok("...badges BOTH parties", /class="pill">author</.test(painted) && /class="pill">answerer</.test(painted));
  // NOTHING is said about the hidden row here — not a tombstone, not an actor,
  // not a link. A moderator clearing a griefing run should leave a shorter page,
  // not a longer one.
  ok("...says nothing at all about the hidden one",
     !painted.includes("Hidden from this list") && !/board\/13"/.test(painted));
  ok("...and names no actor anywhere", !/withdrawn|by its author|moderator/i.test(painted));

  // The toggle is offered only because the sample has a nonzero score. On a
  // board nobody upvoted, Top is byte-for-byte Newest and a toggle between two
  // identical pages is worse than none — orem/1 above proves that branch.
  ok("a board with a real ranking offers the ranked view", painted.includes("best first"));

  await boardView("orem", "1", false);
  ok("a board with no ranking offers no toggle", !painted.includes("best first"));

  // ---- the ranked view ----------------------------------------------------
  await boardView("orem", "2", true);
  ok("the ranked page paints only the rows the score index holds",
     count(/class="boardrow"/g) === 2);
  ok("...so the hidden row is absent, not tombstoned",
     !painted.includes("Hidden from this list"));
  ok("...ranks the highest score first", painted.indexOf("g1answ") < painted.indexOf("g1orem"));
  ok("...shows the score as a score", painted.includes("score 4,712"));
  ok("...and offers the way back to newest", painted.includes("newest first"));
  // Top carries no reply count, so the thread reads on the Newest page.
  ok("...and lists no replies, which that ordering cannot count",
     count(/class="boardkids"/g) === 0);
  // The count must reconcile with BoardSize or the page is quietly hiding rows:
  // 2 of the board's 4 are ranked, and the sentence says which two are not.
  ok("...and reconciles its two rows against the board's four",
     painted.includes("2 of 4 shown") && painted.includes("neither replies nor withheld rows"));

  // ---- the empty and missing cases ----------------------------------------
  await boardView("orem", "9", false);
  ok("an open board with no comments invites the first",
     painted.includes("No comments yet"));
  ok("...and paints no rows at all", count(/class="boardrow"/g) === 0);

  await boardView("orem", "999", false);
  ok("a claim id that does not exist is not found, not an empty board",
     painted.includes("No claim by that id"));

  // ---- hostile text survives the whole path -------------------------------
  // The sample cannot carry an attack, so this drives the real view with one:
  // a comment whose text is markup, arriving through the same parser.
  DEMO.claims["orem/9"] = Object.assign({}, DEMO.claims["orem/9"], {board:{
    size:1, open:true, parties:"",
    newest:'42|g1attacker000000000000000000000000000000|0|.|4799999|<img src=x onerror=alert(1)> & "quoted"'}});
  await boardView("orem", "9", false);
  ok("a comment made of markup reaches the page as text",
     !painted.includes("<img src=x") && painted.includes("&lt;img"));
  ok("...and the row around it still renders", count(/class="boardrow"/g) === 1);

  // ---- the claim page's own comments section --------------------------
  // The thread now sits at the FOOT of the claim page, where a discussion
  // belongs, rather than as a preview above the thing being discussed.
  {
    const R = o => Object.assign({id:1, author:"g1abcdefghijklmnop", mark:".",
                                 at:118803, text:"a comment", replies:"0"}, o);
    const rows = [R({id:3, replies:"1"}), R({id:2, mark:"h", text:""}), R({id:1})];
    const kids = [[R({id:9, text:"a reply"})], [], []];
    const html = claimCommentsHtml("covid", 10, 7, true, rows, kids, {1:"author", 2:"answerer"});

    ok("the section carries the id the claim route renders",
       html.startsWith('<section id="claimcomments">'));
    ok("...heads with the same count and state the chip uses",
       html.includes("7 comments · open for comments"));
    // Every row it is GIVEN — filtering happens in the fill, before this point,
    // so a renderer handed a hidden row would still draw it. That is deliberate:
    // one filter, at one place, rather than a second opinion in the renderer.
    ok("...renders every row it was given, replies included",
       (html.match(/class="boardrow"/g)||[]).length === 4);
    ok("...indents the reply under its parent", html.includes('class="boardkids"'));
    ok("...badges the parties in place",
       /class="pill">author</.test(html) && /class="pill">answerer</.test(html));
    ok("...draws no tombstone for the hidden one",
       !html.includes("Hidden from this list"));
    // 4 rows on the page against a board of 7 — the tail is the honest
    // difference, and it points at the paged view rather than growing this one.
    ok("...links to the rest when it is not showing all of them",
       html.includes("all 7 comments") && html.includes('href="#/c/covid/10/board"'));
    ok("...and carries the composer's slot", html.includes('<div id="composer"></div>'));

    // The removed count comes from the CHAIN, not from the rows on the page:
    // tallying marks client-side undercounts the moment a board outgrows one
    // page, and a header number that quietly means "of the ones we fetched" is
    // worse than none. So it is passed in, and these assert what is done with it.
    const two = claimCommentsHtml("covid", 10, 7, true, rows, kids, {}, 2);
    ok("the header states the count it was given", two.includes("2 hidden comments"));
    ok("...and leaves the site for them, because this one hosts no index of "
       + "withheld content", /class="tlink secact"[^>]*href="https?:[^"]*\/board\/withheld"/.test(two));
    ok("...singular at one",
       claimCommentsHtml("covid", 10, 7, true, rows, kids, {}, 1).includes("1 hidden comment<"));
    ok("...and says nothing at all when nothing was removed",
       !claimCommentsHtml("covid", 10, 7, true, rows, kids, {}, 0).includes("hidden comment"));
    // The page renders four rows; the count is about the whole board, so a
    // number larger than anything on the page is exactly what it should print.
    ok("...even when it exceeds what this section shows",
       claimCommentsHtml("covid", 10, 40, true, rows, kids, {}, 9).includes("9 hidden comments"));
    ok("the count is READ, not counted from the rendered rows",
       /await one\(`BoardHiddenCount\(/.test(src));
  }

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})().catch(e => { console.log("FAIL: the harness died —", e.message); process.exit(1); });
