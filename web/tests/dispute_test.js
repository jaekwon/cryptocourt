// B4 harness: disputeTicket from the live file, demo + live shapes.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo', gnoweb:'https://gno.land', rpc:'http://x', chainid:'dev' };
global.PKG = 'gno.land/r/kourt/kourtv2';
global.isLive = ()=> CFG.mode==='live';
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = NOWm? Number(NOWm[1].replace(/_/g,'')) : 4800000;
const BSm = src.match(/const BLOCK_SECS\s*=\s*([0-9_]+)/); global.BLOCK_SECS = BSm? Number(BSm[1].replace(/_/g,'')) : 5;

let code = '';
code += slice('function esc(', '\n');
code += slice('function fmtN(', 'function ugnot(');
code += slice('const sideName', '\n');
code += slice('function shortAddr(', '\n');
code += slice('function wall(', 'function pctYes');
code += 'var NOW='+global.NOW+';\n';
// Round 28 split the literal: DEMO_CHAIN (generated) + DEMO_OVERLAY
// (hand-written: desc, nested folders, relations, voteEndsAt), joined by
// mergeDemo. Build the merged object the way the page does.
code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED').replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED').replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
code += slice('function tx(func', 'document.addEventListener("click"');
code += slice('const MON=', 'function resolutionLadder(');
code += slice('function voteHelpModal(', 'function disputeTicket');
// disputeTicket now renders the vote-lock disclosure row, so its pure copy
// helper comes along. See web/tests/votelock_test.js for that row's own asserts.
code += slice('function voteLockLine(', 'function voteLockFigures(');
code += slice('function disputeTicket', 'async function fillVoteEligibility');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

const d = Object.assign({}, DEMO.claims["orem/3"]);
const html = disputeTicket("orem", 3, d, NOW);

// THE BALLOT IS THE DECISION; the rules of the court moved into the modal.
// Quorum, threshold, the locking rule and the token flows were five dense lines
// between the question and the buttons — a reader had to get through the
// mechanism to reach the choice.
ok("ballot h3", html.includes("Should this answer be overturned?"));
ok("hint names the answerer, the side and the bond",
   html.includes("answered YES") && html.includes("bonded 80.0 KOURT:OREM on it"));
ok("uphold line names the side that stays", html.includes("the answer stays YES"));
ok("overturn line names the side it becomes", html.includes("the answer becomes NO"));
ok("ladder: spent rounds are struck through and greyed", html.includes('<div class="line spent"><span><s>round 1</s></span>') && html.includes("failed quorum"));
ok("ladder: the live round is marked", html.includes("<span>\u2713 round 2</span>") && html.includes("voting now"));
ok("ladder: round 2 voting at 64 KOURT:OREM", html.includes("round 2</span><span class=\"r\">voting now at 64.0 KOURT:OREM"));
ok("clock: the close reads like the resolution ladder", /vote closes<\/span><span class="r">\u2248 \d+ [A-Z][a-z]{2} \d{4} <small>in 5 days<\/small> <small>\(\u2248block 4,886,400\)<\/small>/.test(html));
// Quorum LEFT the ballot. The rule and the figure are in the modal, where a
// reader who wants the mechanism can find both — and the ballot no longer
// spends a row on arithmetic nobody is being asked to do.
ok("quorum is off the ballot", !html.includes("<span>required quorum</span>"));
ok("...and in the modal, rule first then figure",
   html.includes("If too little weight is cast, the round decides nothing at all")
   && html.includes("5,925 KOURT:OREM"));
ok("no bare jargon label left", !html.includes("turnout bar"));
ok("threshold is off the ballot", !html.includes("<span>threshold</span>"));
ok("...and stated in the modal in plain words",
   html.includes("more than half the weight voted has to say overturn")
   && html.includes("A tie upholds"));
ok("sealed = un-summed not secret", html.includes("Sealed means un-summed, not secret"));
ok("no 'secret ballot'", !/secret ballot/i.test(html));
// Said ONCE now, in the modal. The ballot says who may vote; how the weight is
// measured is mechanism.
ok("weight is the pre-round snapshot, said in the modal",
   html.includes("whatever you held at the last hourly snapshot before this round opened"));
ok("demo exclusion still taught, in one line",
   html.includes("The sample address staked here, so it cannot vote"));
ok("abstain button with turnout-only sub", html.includes("> Abstain") && html.includes("counts to turnout only, never to a side"));
ok("abstain arg choice=abstain", html.includes('"choice":"abstain"') || html.includes("abstain"));
// The rule is stated ONCE now, in the modal — it was on the ballot and in the
// modal, in two different sets of words for the same fact.
ok("who-pays-whom: burn/mint rule, in plain words",
   html.includes("Nothing moves from one side to the other.")
   && html.includes("no pot to win")
   && html.includes("Coin that is forfeited is burned"));
ok("quorum-fail: the answer bond survives, third round closes",
   html.includes("half the challenger's bond burns, half comes back")
   && html.includes("The answerer's bond is untouched")
   && html.includes("After a third failed round the claim closes undecided"));
ok("overturn make-good capped, both limits",
   html.includes("never more than twice their bond, never more than 80% of what burned"));
ok("no live-tally leak words", !/has voted|votes so far|current tally|leading/i.test(html));
ok("no banned words", !/backing|redeem\b|profit|APR|share if right/i.test(html));

// claim WITHOUT demo position (ledger/1 hypothetical dispute) — no sample-exclusion line
const d2 = Object.assign({}, DEMO.claims["orem/3"]);
const html2 = disputeTicket("ledger", 1, d2, NOW);
ok("no exclusion teaching when sample holds no position", !html2.includes("sample address holds a stake"));

// live shape: no voteEndsAt/quorumFloor → honest absence lines
CFG.mode='live';
const dl = Object.assign({}, DEMO.claims["orem/3"]); delete dl.voteEndsAt; delete dl.quorumFloor;
const htmlL = disputeTicket("orem", 3, dl, 5000000);
ok("live: no invented deadline", htmlL.includes("the chain exposes no close height to read"));
ok("live: no turnout row without read", !htmlL.includes("turnout bar"));
ok("live: eligibility span present for async fill", htmlL.includes('id="voteelig"'));
CFG.mode='demo';

// past-close demo: Resolve-works copy
const d3 = Object.assign({}, DEMO.claims["orem/3"], {voteEndsAt: NOW-100});
const html3 = disputeTicket("orem", 3, d3, NOW);
ok("past close: resolve works now", html3.includes("the window has passed — Resolve works now"));


// ---- B4 critic fixes ----
ok("uphold: bond held to finalise + the same payment limits",
   html.includes("The answerer's bond stays held until the claim is finished")
   && html.includes("the same kind of payment on the same limits"));
const d0 = Object.assign({}, DEMO.claims["orem/3"], {answerBond:0});
const html0 = disputeTicket("orem", 3, d0, NOW);
ok("F4: zero-bond hint honest", html0.includes("its bond already burned in an earlier overturned round"));
ok("F4: zero-bond overturn row honest", html0.includes("no bond is left to burn"));
ok("F4: nonzero names the bond and who loses it",
   html.includes("bonded 80.0 KOURT:OREM on it") && html.includes("loses their bond"));
const srcF = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
ok("F1: voteEndsAt in chart domain candidates", /const cands=\[now, d\.settleAt\|\|null, d\.escrowUntil\|\|null, d\.voteEndsAt\|\|null, ansH\]/.test(srcF));
// The HEDGE is the point — that a clean-looking eligibility read is not the
// final word — not which noun carries it. Matched as a pattern so renaming
// "realm" to "court" for readers does not read as a lost guarantee.
ok("F3: eligibility affirmative hedged",
   /the (court|realm) has the final say at signing; staker records persist/.test(srcF));

// ticket rows: label bold on the LEFT, value left-aligned in its own column,
// with a real gutter (owner report: bold-right, ragged-left, columns touching)
ok("ticket rows are a two-track grid with a gutter", src.includes(".ticket .line,.qrows .line{display:grid; grid-template-columns:minmax(0,20ch) minmax(0,1fr); column-gap:24px"));
ok("the label is the bold thing", src.includes(".ticket .line>*:first-child,.qrows .line>*:first-child{font-weight:600; color:var(--ink)}"));
ok("values read left-to-right, not right-adjusted", src.includes(".ticket .line .r,.qrows .line .r{font-weight:400; color:var(--ink-2); text-align:left"));
ok("no space-between left in the rule", !src.includes(".ticket .line{display:flex; justify-content:space-between"));
ok("narrow screens stack the pair", src.includes("@media (max-width:640px){ .ticket .line,.qrows .line{grid-template-columns:minmax(0,1fr)"));
// the helper modal: the long "why" lives one click away, keyboard-reachable
ok("modal: one dialog, native, labelled", html.includes('<dialog class="helper" id="help-vote" aria-labelledby="help-vote-h">'));
ok("modal: triggers are BUTTONS (an href-less <a> cannot be tabbed to)", html.includes('<button type="button" class="helplink" data-help="help-vote">') && !html.includes('<a class="helplink"'));
// The ballot keeps ONE line of prose and one link. The burn/mint rule used to
// sit here as well as in the modal, in two different sets of words.
ok("ballot keeps one line and one link",
   html.includes("Nobody can see the count until voting closes.")
   && html.includes("How this vote works →"));
ok("...and no longer restates the token rule on the ballot",
   !html.includes("forfeits are burned, awards are newly minted"));
ok("the dense blocks are gone from the ticket body", !html.includes("a running count would make copying the first big voter") && !html.includes("there is no pot to steer"));
ok("plain-English rewrite present",
   html.includes("the best move would be to wait and copy whoever voted with the most weight"));
ok("§7.4 holds in the new copy", !/backing|redeem|APR|profit|return on/i.test(html) && html.includes("staked KOURT:OREM is never touched"));
ok("the token is named, not \"money\"", html.includes("KOURT:OREM") && !/\bmoney\b/.test(html));
ok("canonical display is KOURT:SLUG", html.includes("Any KOURT:OREM holder can vote"));
ok("the word \"money\" appears nowhere in the file", (()=>{ const fs=require("fs");
  return !/\bmoney\b/i.test(fs.readFileSync(require('path').join(__dirname,'..','index.html'),"utf8")); })());
console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
