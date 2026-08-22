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
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.CFG = { mode:'live', gnoweb:'https://gno.example/' };
global.isLive = ()=> CFG.mode==='live';

let code = '';
code += slice('function esc(', '\n');
code += slice('function tx(', 'function btn(');
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

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
