// The author's polish window: EditClaimTitle, offered only while it could work.
//
// WHY THIS EXISTS. The realm has let an author fix a claim's title since it was
// written — before the first stake, before the opening delay passes, author
// only. Nothing in the product called it. A sweep of crossing entrypoints
// against the two shipped web files found it among nine others, and it is the
// one that mattered most for a reason the others did not share: THE WINDOW
// EXPIRES. A feature the product cannot reach is missing; a timed one the
// product cannot reach is missing and then gone.
//
// So the offer has to appear while it can still succeed and vanish when it
// cannot, and every "vanish" below is a case where showing it would send an
// author to a form the realm is going to refuse.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice } = require("./srcslice");
global.CFG = { mode:'live', gnoweb:'https://gno.example/' };
global.isLive = ()=> CFG.mode==='live';

let code = '';
code += slice('function esc(', '\n');
code += slice('function tx(', 'function btn(');
// btn and stakeTicket, for the blocked-control block at the end: a greyed
// button is a decision btn() makes from an argument stakeTicket() computes, and
// asserting on either alone would miss the wiring between them.
code += "const PKG='gno.land/r/kourt/kourtv2';\n";
code += slice('const ICN_CHEST =', 'const ICN_COURT =');
// the gas pair the wallet and the printed command share — sliced, never retyped
code += slice('const GAS_WANTED', 'const CFG_DEFAULTS');
code += slice('const shq =', 'function cliCmd(');
code += slice('function cliCmd(', '/* A copyable command block');
code += slice('function btn(', '/* SHELL-QUOTED');
code += slice('function ccSym(', 'function cc(');
code += slice('function cc(', 'function ugnot(');   // cc is two lines, not one
code += slice('function fmtN(', 'function ugnot(');
code += slice('function stakeTicketHasActions(', 'function focusStakeSide(');
code += slice('function polishLink(', '\nfunction modBanner(');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

const open = {phase:"open", title:"Was it so?", yesStake:0, noStake:0};
// 600 blocks of polish window. The court must HAVE one — see the last block.
const W = 600;

// It is offered, and it carries the CURRENT title so the form opens on the text
// being fixed rather than on an empty field the author has to retype.
const html = polishLink("orem", 7, open, null, null, W);
ok("offered while the claim is open and unstaked", html.includes("fix the title"));
ok("it points at EditClaimTitle", html.includes("func=EditClaimTitle"));
ok("for this court and claim", html.includes("courtSlug=orem") && html.includes("claimID=7"));
ok("prefilled with the title being fixed", html.includes(encodeURIComponent("Was it so?")));
ok("and it leaves the app rather than pretending to be a route",
   html.includes('target="_blank"') && html.includes('rel="noopener"'));

// EVERY WITHDRAWAL IS A REFUSAL THE REALM WOULD HAVE MADE. Showing the offer in
// any of these sends an author to a form that cannot succeed.
ok("gone once YES is staked", polishLink("orem",7,{...open, yesStake:1},null,null,W)==="");
ok("gone once NO is staked",  polishLink("orem",7,{...open, noStake:1},null,null,W)==="");
ok("gone when the claim is answered", polishLink("orem",7,{...open, phase:"frozen"},null,null,W)==="");
ok("gone when the claim died", polishLink("orem",7,{...open, phase:"closed"},null,null,W)==="");
// A withheld title must not be offered for editing: the page will not show the
// text, so the form would invite an edit to something the author cannot read
// here, and the moderation gate is not the client's to second-guess.
ok("gone when the title is purged", polishLink("orem",7,open,true,null,W)==="");
ok("gone when the title is redacted", polishLink("orem",7,open,null,true,W)==="");
// Demo data with a live tx link is the trap btn() refuses for the same reason:
// it would point a real network at a sample claim.
CFG.mode='demo';
ok("gone in demo mode", polishLink("orem",7,open,null,null,W)==="");
CFG.mode='live';
// Nothing to reason about yet — a page that has not read the claim must not
// guess that the window is open.
ok("gone when there is no claim data", polishLink("orem",7,null,null,null,W)==="");

// THE COURT MUST HAVE A WINDOW AT ALL, which is the condition the first version
// of this missed entirely and would have shipped without. StartCourt passes
// stakeOpenDelay 0 and only StartCourtP opts in, so on a court made the ordinary
// way the title freezes before the opening transaction returns and
// EditClaimTitle refuses every call. Offering "fix the title" there is a link
// that cannot work, on almost every court in existence.
ok("gone when the court has no polish window", polishLink("orem",7,open,null,null,0)==="");
ok("gone when the realm cannot say", polishLink("orem",7,open,null,null,null)==="");
ok("offered when the court opted into one", polishLink("orem",7,open,null,null,1).includes("fix the title"));


/* A CONTROL THE CHAIN WOULD REFUSE SAYS SO BEFORE THE SIGNATURE. Crystallize was
   offered on every settled, un-crystallized claim, and the realm turns it down in
   four states (crystallize.gno): an open quality question, the 24h quiet window
   after the last flag event, and the first week of the verdict for anyone who is
   not a participant.
   Only the first is greyed, because it is the only one this page can evaluate —
   flagOpen and counterOpen are already read for the quality lane, while the
   quiet window needs lastFlagEventAt and the participant week needs the reader's
   own stake, and neither is published. Those get a note stating the rule.
   GREYING A CONTROL SOMEBODY COULD HAVE USED is worse than offering one they
   cannot, so the unknown cases stay live. */
{
  const settled = {phase:"settled", verdict:0, answer:0, route:"vote", crystallized:false,
                   yesStake:180, noStake:20};
  const clear = stakeTicket("orem", 4, settled);
  const crysOf = h => (h.match(/<button[^>]*>(?:(?!<\/button>)[\s\S])*?Open the rewards[\s\S]*?<\/button>/)||[""])[0];
  /* THE GREYED CASE IS GONE, not weakened. Three assertions here covered
     Crystallize being blocked while a quality question was open — an open flag
     vote or a counter window — and named the reason ("the draw waits, not the
     principal") and its aria-disabled state. Both states went with the quality
     lane, so there is no longer any reason the page can KNOW that blocks the
     draw; the remaining wait is the participant week, which the hint explains
     and which the assertion below covers.
     Kept: the control must stay LIVE when the page cannot know, because greying
     something somebody could have used is the worse error. That is the half of
     this block that still has a subject. */
  ok("crystallize stays live when the page cannot know the answer",
     !/data-blocked=/.test(crysOf(clear)));
  /* THE RULE MOVED INTO THE HINT, where a sentence fits. "participants first
     week" assumed the reader knew there was a priority window, what a
     participant is, and that anything had to be opened at all — three things a
     first-time reader cannot know, in a note too short to say any of them. */
  /* THE CARD IS A HEADING AND BUTTONS. The paragraph explaining that principal
     returns 1x, and the two-row table saying it again, are gone: they were true
     of every claim in every court, on a card whose reader has one question left.
     The one fact this card alone carried — who may open the rewards — rides the
     button that opens them. */
  ok("...and the card is down to its heading and its controls",
     /Staking is closed/.test(clear)
     && !/<div class="hint">/.test(clear)
     && !/class="line"/.test(clear));
  ok("...and no longer claims nothing has paid out, above a live withdraw",
     !/Nothing has paid out/.test(clear) && !/Your principal is yours now/.test(clear));
  // NO ELIGIBILITY NOTE ANYWHERE. It named the schedule rather than answering
  // whether the reader can press it, which is the only version of that fact
  // worth the width. What the page CAN evaluate is still greyed; the rest the
  // press answers.
  ok("...and no eligibility schedule under the button",
     !/participants first week/.test(clear) && !/then anyone/.test(clear));
  /* THE PARTICIPANT WEEK IS GREYED, NOT DISCOVERED IN THE WALLET. Crystallize
     is participant-only for FINALIZE_GRACE blocks after the verdict, and the
     page used to offer it to everyone — a reader pressed it and got
     "kourtv2: Crystallize is participant-only for its first week" relayed
     through Adena. isParticipant is author, answerer, or a stake on either side
     (dispute.gno:803), and fillWithdrawSides has all three in hand.
     Driven through all six cases in a browser besides: a stranger inside the
     week is the only one greyed. */
  ok("...the button is marked so the filler can find it in the sample too",
     /data-crys="1"/.test(clear));
  ok("...the guard is gated on the mirrored window, not a literal",
     /\(nowH - vAt\) < FINALIZE_GRACE/.test(src));
  /* AND THE NOTE BESIDE IT SAYS THE SAME THING WITHOUT A CLICK. The greyed
     button carries the reason in data-blocked, which blocked buttons reveal only
     when pressed — so a reader with no stake was told two facts a press apart.
     TIED TO THE SAME CONDITION, not re-derived: the sentence is appended off the
     flag the greying sets, so it cannot appear after the week has lapsed, when
     anyone may open the rewards and it would be false. */
  ok("...and the no-stake note explains the week when the week is running",
     /graceLocked = true;/.test(src)
     && /graceLocked[\s\S]{0,120}only those with stake may pick/.test(src));
  ok("...and says nothing extra once the week has lapsed",
     /graceLocked\s*\?[\s\S]{0,220}:\s*""/.test(src));
  /* BOTH HEIGHTS FROM THE SAME CLOCK. chainHeight() asks the RPC for the latest
     block; a verdict height comes from ClaimTimeline, which the realm answers
     from heightNow() — chain height PLUS the test skew. On a seeded chain those
     differ by design, and the first version passed one of each: 3 against
     23,040. The subtraction went negative, negative is below the grace window,
     and the guard greyed every claim on the chain forever. ClaimTimeline puts
     `now` beside `verdict` so a consumer can subtract two heights that mean the
     same thing. */
  ok("...and both heights come from the timeline, not one from the RPC",
     /fillWithdrawSides\(slug, id, d,\s*\n\s*tline && tline\.now\? tline\.now\.h : nowH,/.test(src));
  ok("...it greys only when author, answerer and stake all say no",
     /party\.author!==CFG\.addr && party\.answerer!==CFG\.addr/.test(src)
     && /!\(\+p\.yes > 0\) && !\(\+p\.no > 0\)/.test(src));
  ok("...and stands whenever any of them is unknown",
     /vAt && nowH!=null/.test(src) && /party\.author!=null && party\.answerer!=null/.test(src));
  /* AND IT FETCHES ITS OWN INPUTS. The first version read the parties off `d`,
     where the route had never put the author and the sample had never carried
     the answerer on its settled claim — so it bailed silently and shipped
     greying nothing at all. A control deciding whether to grey itself cannot
     trust that its caller populated the fields. */
  ok("...and reads the parties rather than trusting the caller",
     /async function claimParties\(slug, id, d\)/.test(src)
     && /one\(`ClaimAuthor\(\$\{s2\},\$\{id\}\)`\)/.test(src)
     && /one\(`Answerer\(\$\{s2\},\$\{id\}\)`\)/.test(src));
  ok("...saying who may, in the page's own words",
     /author, its answerer and its stakers can open the rewards in the first week/.test(src));
  // The chest: this button collects rather than signs a statement.
  // The chest is INTERPOLATED, so the rendered card holds the svg, not the name.
  ok("...and it carries the chest rather than the pen",
     /<span class="g"><svg class="icn"/.test(crysOf(clear))
     && !/<span class="g">✍/.test(crysOf(clear)));

  // The withdraw pair is marked for the position read that filters and prices it.
  ok("...and the withdraw pair is marked for the position read",
     /data-wside="0"/.test(clear) && /data-wside="1"/.test(clear));
  ok("...and the button says the verb, with the rule as its note",
     /Open the rewards/.test(crysOf(clear)));
  // Once they are open the card stops explaining how to open them.
  ok("a crystallized claim does not still describe opening",
     !/have to be opened first/.test(
       stakeTicket("orem", 4, Object.assign({}, settled, {crystallized:true}))));
  // The withdraw buttons beside it are never blocked — principal is never gated.
  ok("withdrawing principal is never blocked",
     !/data-blocked/.test((clear.match(/<button[^>]*>(?:(?!<\/button>)[\s\S])*?Withdraw[\s\S]*?<\/button>/)||[""])[0]));
}

/* NOTHING BELOW THIS RUNS. The summary is followed by process.exit, so a block
   appended to the end of this file is dead code that reports ALL PASS — which
   is exactly what happened to the block above the first time it was written
   here. New cases go ABOVE this line. */
console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
