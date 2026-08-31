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
// voteLockFigures came in via the voteLockLine slice, which ended at it; that
// slice went when the row did, so it is pulled in on its own now.
code += slice('function voteLockFigures(', 'async function fillVoteCommitment(');
code += slice('function parseCommitments(', '/* ---------------- the associations');
eval(code);

let fail = 0;
function ok(what, cond){ if(cond){ console.log("ok: "+what); } else { fail++; console.log("FAIL: "+what); } }

// ---- the surviving row, and the rule the other lane still owes a reader ----
// ONE ROW NOW. The dispute ballot was cut back to the question and the buttons,
// so the verdict lane has no row to render — but the OBLIGATION did not go
// anywhere, and this harness exists because that obligation was undisclosed for
// many rounds. So the verdict rule is asserted where it landed rather than
// deleted along with its row: prose in the modal, figures on the me-page.
// THE ROW BECAME MODAL COPY. qualityLockLine was printed by qualitySection,
// which went with the quality lane; putting it on the ballot instead would have
// contradicted dispute_test.js, which pins the ballot down to the question, the
// clock and the buttons. So the sentence is now inside "How this vote works" and
// is asserted against the modal's source rather than a function's return.
const Q = slice('<h4>What casting costs you</h4>', '<h4>Flagging a claim as spam</h4>');
// The modal, sliced out so "the ballot no longer says it" and "the modal does"
// are two different subjects. Asserting both against the whole file would pass
// on either one alone.
const MODAL = (() => { const a = src.indexOf('id="help-vote"'); return src.slice(a, src.indexOf("</dialog>", a)); })();

ok("the verdict release rule is in the modal", /locked until this round ends/.test(MODAL));
ok("...and no row function renders it any more", !/function voteLockLine/.test(src));
ok("...the figures span lives in the modal, not in a ballot row",
  /id="votecommit"/.test(MODAL));
// THE TWO-LANE SPLIT IS GONE, and these two assertions went with it. They existed
// because the quality row's release was a DIFFERENT event from the verdict row's —
// a quality tally could freeze and carry into later rounds, so it named "the claim
// itself ends" while the verdict named "this round ends", and the danger was one
// silently inheriting the other's wording. With one vote left there is one release
// event, and asserting that it does not reuse itself is not a check.
//
// What replaced them is the assertion above: the sentence is in the modal, and no
// row form of it survives to drift from the modal's copy.
ok("the surviving copy names the round, which is when it releases",
   /until this round resolves/.test(Q));
// ONE SURFACE NOW, AND THAT IS WHY THIS BLOCK SHRANK. Nine assertions here were
// of the form "BOTH surfaces say X", pairing the quality ROW against the MODAL —
// the point being that two copies of one rule must not drift apart. The row went
// with the quality lane and its sentence moved into the modal, so Q is a slice OF
// the modal and every "both" assertion compares it to itself: true by
// construction, and therefore a check of nothing.
//
// What survives is each substantive guarantee, asserted once against the copy that
// exists. These are not stylistic — mustStakable deliberately ignores the vote
// lock, so copy implying otherwise costs a holder a legitimate action, which is
// the failure this whole block was written to prevent.
ok("it says the coin can still be staked", /you can still stake it/.test(MODAL));
ok("...and that it stays in the balance and keeps voting",
   /stays in your balance and keeps voting/.test(MODAL));
ok("...and names exactly what it cannot back",
   /cannot also back a bond, a deposit or a transfer/.test(MODAL));
ok("...and says when it releases", /until this round resolves/.test(MODAL));
ok("...and carries the span its filler writes into", /id="votecommit"/.test(MODAL));
// Asserted as the POSITIVE claim rather than a banned-word list: the first version
// banned "frozen", which the quality lane used correctly of the TALLY.
ok("it never says the coin leaves or is locked away",
   !/leaves your balance|locked away|taken from/i.test(MODAL));
// The phrasing that went stale in three documents. A tally was superseded only by
// a NEW ROUND, and nothing makes a round open, so it promised a release that might
// never come.
ok("it does not say 'superseded'", !/supersed/i.test(MODAL));
// House style: §7.4 keeps trading language off these surfaces.
ok("no banned words in the disclosure",
   !/backing|redeem\b|profit|APR|odds|price/i.test(MODAL));

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

// ---- the wiring: the row is on the panel that has one ----
// NOT ON THE BALLOT. I wrote this the other way round first — moving the row onto
// the ballot was the obvious repair when qualitySection went — and dispute_test.js
// refused it: the ballot is deliberately the question, the clock and the buttons,
// and the owner asked for it that way. The copy belongs in the modal, asserted
// above; what is asserted here is that it did NOT land on the ballot.
ok("the ballot does not carry a vote-lock row", !/voteLockLine\(\)/.test(src));
// The ballot is the question and the buttons. A lock row reappearing there is
// the regression this asserts, not a style preference: it was removed WITH the
// outcome rows and the round ladder, and the modal took over its rule.
// THE CALL, not the row's words: the first version of this looked for "voting
// locks" inside disputeTicket and an ablation that put `${qualityLockLine()}`
// straight into the ballot walked past it — the words live in the callee. What
// dispute_test.js asserts is the rendered ballot; what this asserts is the call.
ok("the dispute ballot carries no lock row",
  !/function disputeTicket[\s\S]{0,1400}LockLine\(/.test(src));
// THE WRAPPER CLASS IS THE ASSERTION, not the div. Every rule for a .line was
// written as `.ticket .line`, and this panel has no ticket — so the row came out
// as two bare inline spans reading "what voting commitsCasting commits the
// weight you vote with…": the label and its prose printed as one word, with no
// emphasis and no column. Rendering it and reading it is what found that.
// THE ROW IS GONE; THE DEFECT IT WAS FOUND BY IS NOT. The vote-lock row moved into
// the modal, so only the reward-pool row is left in a panel — and it is the one
// that has to keep its .qrows wrapper, for the reason above: every rule for a .line
// was written as `.ticket .line`, this panel has no ticket, and without the wrapper
// the row prints as two bare inline spans running the label into its prose.
ok("the reward-pool row keeps its .qrows wrapper",
   /function rewardsSection[\s\S]{0,400}<div class="qrows"><div class="line">/.test(src));
ok("...in a context the ticket row styles actually reach",
   /\.ticket \.line,\.qrows \.line\{display:grid/.test(src));
ok("the claim page calls the filler", src.includes('fillVoteCommitment(slug,id);'));

// DisposableOf is the figure the realm enforces. SpendableOf is stake-only and
// over-promises by the whole of a vote commitment.
ok("the filler reads DisposableOf", src.includes('DisposableOf(${gstr(slug)},${gstr(CFG.addr)})'));
// A CALL, not a mention: the comment above the filler names SpendableOf in order to
// say not to use it, and banning the word would ban the explanation.
ok("nothing in the client CALLS SpendableOf", !/SpendableOf\(/.test(src));
ok("the filler reads the committed total", src.includes('VoteLockedOf(${gstr(slug)},${gstr(CFG.addr)})'));

// THE INDEX IS THE ASSERTION. ClaimVoteWeightOf returns (verdict, quality) and
// the two weigh at different epochs. With only one row left, w[0] would render a
// verdict-epoch figure under a quality question and NOTHING on the page would
// look wrong — the tuple is the only thing that can catch it.
ok("the quality span is fed the quality weight, index 1",
  src.includes('qv.textContent = voteLockFigures(slug, w? w[1]: null'));
ok("...and the verdict weight is not read into it",
  !/textContent = voteLockFigures\(slug, w\? w\[0\]/.test(src));

// A failed read must not break the panel, and demo mode must not query a chain.
ok("the filler is gated on live mode and an address", src.includes('if(!qv || !CFG.addr || !isLive()) return;'));
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
ok("the ticket says the free figure is the enforced one", /the figure the (court|realm) enforces/.test(T));
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
