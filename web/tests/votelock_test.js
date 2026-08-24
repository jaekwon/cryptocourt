// Vote-lock disclosure harness: the copy, the figures, and the wiring.
//
// WHY THIS EXISTS. The vote lock is a commitment the realm enforces at signing and
// this overlay disclosed nowhere — VOTEFLOOR.md carried the finding for many rounds
// as a handoff. The copy is the deliverable, so the copy is what is asserted: the
// two lanes must give DIFFERENT release rules, neither may use the phrasing that was
// already found wrong, and neither may claim staking is refused when it is not.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo' };
global.isLive = ()=> CFG.mode==='live';

let code = '';
code += slice('function esc(', '\n');
code += slice('function fmtN(', '\n');
code += slice('function ccSym(', '\n');
code += slice('function cc(', 'function ugnot(');
code += slice('function voteLockLine(', 'async function fillVoteCommitment(');
code += slice('function parseCommitments(', '/* ---------------- the associations');
eval(code);

let fail = 0;
function ok(what, cond){ if(cond){ console.log("ok: "+what); } else { fail++; console.log("FAIL: "+what); } }

// ---- the two lanes say different things, and neither says the wrong thing ----
const V = voteLockLine("verdict", "votecommit");
const Q = voteLockLine("quality", "qualcommit");

ok("the verdict lane releases on its round", /until this round resolves/.test(V));
ok("the quality lane does NOT reuse the verdict rule", !/until this round resolves/.test(Q));
ok("the quality lane names the claim ending", /the claim itself ends/.test(Q));
ok("the quality lane names its own question closing", /when it closes/.test(Q));
// The phrasing that went stale in three documents. A tally is superseded only by a
// NEW ROUND, and nothing makes a round open, so this sentence promises a release
// that may never come.
ok("neither lane says 'superseded'", !/supersed/i.test(V) && !/supersed/i.test(Q));

// Staking is the deliberate exemption — mustStakable ignores the vote lock. Copy
// that says otherwise costs a holder a legitimate action.
ok("both lanes say the coin can still be staked", /can still be staked/.test(V) && /can still be staked/.test(Q));
ok("both lanes say it keeps voting", /keeps voting/.test(V) && /keeps voting/.test(Q));
ok("both lanes name what it cannot back", /cannot also back a bond, a deposit or a transfer/.test(V)
  && /cannot also back a bond, a deposit or a transfer/.test(Q));
// Asserted as the POSITIVE claim rather than a banned-word list: the first version
// of this banned "frozen", which the quality lane uses correctly of the TALLY.
ok("both lanes say the coin stays in the balance", /stays in your balance/.test(V) && /stays in your balance/.test(Q));
ok("neither lane says the coin leaves or is locked away", !/leaves your balance|locked away|taken from/i.test(V+Q));

// The lanes weigh at DIFFERENT epochs, so their figures must land in different
// elements. One span for both is the defect VoteWeightWhy was split in two to fix.
ok("each lane carries its own span id", /id="votecommit"/.test(V) && /id="qualcommit"/.test(Q));
ok("the two span ids differ", !/qualcommit/.test(V) && !/votecommit/.test(Q));

// House style: §7.4 keeps trading language off these surfaces.
ok("no banned words in the disclosure", !/backing|redeem\b|profit|APR|odds|price/i.test(V+Q));

// ---- the figures: a missing read prints nothing, never a zero ----
ok("no figures at all renders nothing", voteLockFigures("orem", null, null, null) === "");
ok("a zero would-commit is omitted, not printed as 0", voteLockFigures("orem", 0, null, null) === "");
// Format-agnostic on purpose: cc() gives two decimals below ten and one above, so
// pinning "12.00" pinned the formatter rather than the disclosure.
ok("a would-commit is quoted in the court's own unit",
  /this vote would commit [\d,.]+ KOURT:OREM/.test(voteLockFigures("orem", 12_000_000, null, null)));
ok("an existing commitment is named separately",
  /already committed by voting: 5\.00 KOURT:OREM/.test(voteLockFigures("orem", null, 5_000_000, null)));
// Zero FREE is meaningful and must show: "nothing is free" is the disclosure.
ok("zero free-to-bond is shown rather than omitted",
  /free to bond or deposit right now: 0\.00 KOURT:OREM/.test(voteLockFigures("orem", null, null, 0)));
ok("all three figures can appear together",
  (f => /would commit/.test(f) && /already committed/.test(f) && /free to bond/.test(f))
    (voteLockFigures("orem", 1_000_000, 2_000_000, 3_000_000)));

// ---- the wiring: the row is actually on both panels and fed the right lane ----
ok("the dispute ballot carries the verdict row",
  src.includes('${voteLockLine("verdict","votecommit")}'));
ok("the quality panel carries the quality row",
  src.includes('voteLockLine("quality","qualcommit")'));
ok("the quality row renders in the panel", src.includes('${qlock?`<div style="margin-top:8px">${qlock}</div>`:""}'));
ok("the claim page calls the filler", src.includes('fillVoteCommitment(slug,id);'));

// DisposableOf is the figure the realm enforces. SpendableOf is stake-only and
// over-promises by the whole of a vote commitment.
ok("the filler reads DisposableOf", src.includes('DisposableOf(${gstr(slug)},${gstr(CFG.addr)})'));
// A CALL, not a mention: the comment above the filler names SpendableOf in order to
// say not to use it, and banning the word would ban the explanation.
ok("nothing in the client CALLS SpendableOf", !/SpendableOf\(/.test(src));
ok("the filler reads the committed total", src.includes('VoteLockedOf(${gstr(slug)},${gstr(CFG.addr)})'));

// The lanes must not be crossed: ClaimVoteWeightOf returns (verdict, quality).
ok("the verdict span is fed the verdict weight",
  src.includes('dv.textContent = voteLockFigures(slug, w? w[0]: null'));
ok("the quality span is fed the quality weight",
  src.includes('qv.textContent = voteLockFigures(slug, w? w[1]: null'));

// A failed read must not break the panel, and demo mode must not query a chain.
ok("the filler is gated on live mode and an address", src.includes('if((!dv && !qv) || !CFG.addr || !isLive()) return;'));
ok("every read has its own catch", (src.match(/\.catch\(\(\)=>null\)\]?\),?\n?/g)||[]).length >= 3);

// ---- the me-page: one read per court, and the total is not the sum ----
// This fixture is a string the REALM actually produced, captured from the ablation
// run in TestCommitmentsOfIsOneReadAndItsTotalIsAMaxNotASum: two open commitments of
// 20 and 1, whose total is the larger and not the 21 they add to.
const REAL = "stake:0;vote:20000000000;free:0;q:d:1:1:20000000000;q:q:1:1:1000000000";
const C = parseCommitments(REAL);
ok("the parser reads the three totals", C.stake===0 && C.vote===20000000000 && C.free===0);
ok("the parser reads both commitment rows", C.q.length===2);
ok("a verdict row keeps its lane and claim", C.q[0].kind==="d" && C.q[0].id===1 && C.q[0].amt===20000000000);
ok("a quality row keeps its own lane", C.q[1].kind==="q" && C.q[1].amt===1000000000);
ok("the rows sum to MORE than the total, which is the point",
  C.q.reduce((t,r)=>t+r.amt,0) > C.vote);
ok("a failed read parses to nothing", parseCommitments(null)===null && parseCommitments("")===null);
ok("an unknown key is ignored rather than assigned",
  (()=>{ const x=parseCommitments("stake:1;bogus:9;vote:2;free:3"); return x.stake===1 && x.vote===2 && x.free===3 && x.bogus===undefined; })());
ok("a short q record is skipped rather than half-read",
  parseCommitments("stake:0;vote:0;free:0;q:d:1").q.length===0);

const T = commitmentsTicket(C, "orem");
ok("no read renders no block", commitmentsTicket(null,"orem")==="");
ok("the ticket names all three totals",
  /committed by voting/.test(T) && /committed as stake/.test(T) && /free to bond, deposit or transfer/.test(T));
ok("the ticket says the free figure is the enforced one", /the figure the realm enforces/.test(T));
// The trap: two commitments, one pile. Saying "total" would invite the reader to add.
ok("with several rows the copy denies the sum", /not their total/.test(T));
ok("with one row it does NOT say that",
  !/not their total/.test(commitmentsTicket(parseCommitments("stake:0;vote:5;free:0;q:d:1:1:5"),"orem")));
ok("a claim row shows its claim, an election row shows its election",
  /on claim #1/.test(T)
  && /#7/.test(commitmentsTicket(parseCommitments("stake:0;vote:5;free:0;q:e:0:7:5"),"orem")));

ok("the me-page reads it once per court",
  src.includes('CommitmentsOf(${gstr(slug)},${gstr(addr)})'));
ok("the me-page read is gated and caught",
  src.includes('if(isLive()) com = parseCommitments(await one(`CommitmentsOf(${gstr(slug)},${gstr(addr)})`).catch(()=>null));'));
ok("the block renders in the court's section", src.includes('+ commitmentsTicket(com, slug)'));

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
