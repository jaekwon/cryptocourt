// C3 harness: claimables() decision table, diffSeen(), senior demo shape,
// needs deadline/section logic strings, §7.4 sweep.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo', chainid:'dev' };
global.isLive = ()=> CFG.mode==='live';
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = Number(NOWm[1].replace(/_/g,''));

let code = '';
code += slice('function esc(', '\n');
code += 'var NOW='+global.NOW+';\n';
code += 'const sideName = o => o===0?"YES":o===1?"NO":"—";\n';
code += slice('function claimables(', 'function seenKey').replace('function claimables','function claimables');
code += slice('function seenKey(', 'let DETC');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };
const ME="g1me";
const P_STAKE={yes:5,no:0,cy:2,cn:0}, P_CONV={yes:0,no:0,cy:2,cn:0}, P_NONE={yes:0,no:0,cy:0,cn:0};
const pulls0={winnerPaid:false,authorPaid:false,answererPaid:false};

// stake withdrawals
ok("settled+stake → withdraw 1×", claimables("c",1,{phase:"settled"},P_STAKE,ME,100).now.some(r=>r.label.includes("returns 1×")));
ok("provClose+stake → withdraw", claimables("c",1,{phase:"provClose"},P_STAKE,ME,100).now.length===1);
ok("provisional losing side → leave with 1×", claimables("c",1,{phase:"provisional",provisional:1},P_STAKE,ME,100).now.some(r=>r.label.includes("1× now")));
ok("provisional winning side → no stake row", claimables("c",1,{phase:"provisional",provisional:0},P_STAKE,ME,100).now.length===0);
ok("closed → unstake wording", claimables("c",1,{phase:"closed"},P_STAKE,ME,100).now.some(r=>r.label.includes("unstake")));
ok("open → nothing", claimables("c",1,{phase:"open"},P_STAKE,ME,100).now.length===0);

// crystallized draws via paid flags
const D4 = {phase:"settled",crystallized:true,verdict:0,answer:1,route:"vote",author:ME,answerer:"g1x",draw:{w:1,a:2,ans:0,carrot:5},pulls:pulls0};
const c4 = claimables("orem",4,D4,{yes:20,no:0,cy:10,cn:0},ME,100);
ok("winner draw when side==verdict & !paid", c4.now.some(r=>r.label.includes("accuracy reward")));
ok("author draw when author & !paid", c4.now.some(r=>r.label.includes("author's slice")));
ok("no answerer row for non-answerer", !c4.now.some(r=>r.label.includes("answerer")));
ok("stake withdraw also present", c4.now.some(r=>r.label.includes("returns 1×")));
const c4paid = claimables("orem",4,{...D4,pulls:{winnerPaid:true,authorPaid:true,answererPaid:true}},{yes:20,no:0,cy:10,cn:0},ME,100);
ok("paid flags suppress draws", !c4paid.now.some(r=>r.label.includes("reward")||r.label.includes("slice")));
const cAns0 = claimables("orem",4,{...D4,author:"g1a",answerer:ME},{yes:0,no:0,cy:0,cn:1},ME,100);
ok("overturned answerer: decisive nothing", cAns0.now.some(r=>r.decisive && r.label.includes("draws nothing")));
const cLoser = claimables("orem",4,D4,{yes:0,no:20,cy:0,cn:10},ME,100);
ok("losing side gets no reward row", !cLoser.now.some(r=>r.label.includes("accuracy reward")));
ok("null pulls (failed read) → no draw rows, never guessed", !claimables("orem",4,{...D4,pulls:null},{yes:20,no:0,cy:10,cn:0},ME,100).now.some(r=>r.label.includes("reward")));

// carrot: participants excluded — a scanned (staked) hit never hedges
ok("staker gets NO carrot hedge", claimables("orem",4,{...D4,author:"g1a"},P_STAKE,ME,100).maybe.length===0);
ok("conviction-only participant: NO hedge", claimables("orem",4,{...D4,author:"g1a"},P_CONV,ME,100).maybe.length===0);
ok("non-participant would hedge", claimables("orem",4,{...D4,author:"g1a"},P_NONE,ME,100).maybe.length===1);

// finalize
ok("finalize when escrow passed + participant", claimables("c",1,{phase:"provisional",provisional:0,escrowUntil:90},P_STAKE,ME,100).now.some(r=>r.label.includes("finalize")));
ok("no finalize before escrow", !claimables("c",1,{phase:"provisional",provisional:0,escrowUntil:200},P_STAKE,ME,100).now.some(r=>r.label.includes("finalize")));
ok("no finalize for stranger", !claimables("c",1,{phase:"provisional",provisional:0,escrowUntil:90,author:"g1a",answerer:"g1b"},P_NONE,ME,100).now.some(r=>r.label.includes("finalize")));

// diffSeen
ok("diff: transition detected", diffSeen({h:1,claims:{"o/3":"answered"}},{h:2,claims:{"o/3":"disputed"}}).length===1);
ok("diff: no prior → empty", diffSeen(null,{h:2,claims:{"o/3":"x"}}).length===0);
ok("diff: unseen claim ignored", diffSeen({h:1,claims:{}},{h:2,claims:{"o/9":"open"}}).length===0);
ok("diff: unchanged → empty", diffSeen({h:1,claims:{"o/3":"open"}},{h:2,claims:{"o/3":"open"}}).length===0);

// source-level checks
ok("snapshot only when mefail==0", src.includes("if(mefail===0) store.set(seenKey(addr)"));
ok("last-visit copy verbatim", src.includes("this browser's memory of your last look") && src.includes("Clear storage and it forgets"));
ok("senior owed-not-earned copy", src.includes("owed, not earned") && src.includes("paid as budget accrues, the court's pace, not a promise"));
ok("needs deadline string", src.includes("you may dispute until ≈block"));
// HONESTY IS STILL THE POINT, but the honest sentence changed when
// DisputeVoteCloses shipped: the chain does publish a close now, so claiming it
// does not was the dishonest version. The row still carries no countdown —
// reading it here would be a query per row — and it says where to find one.
ok("needs sealed-vote honesty",
   src.includes("a sealed vote is deciding — its countdown is on the claim page")
   && !src.includes("no close height is published"));
ok("needs sections", src.includes(">Against your side <span") && src.includes(">With your side <span"));
ok("no cross-court sums", src.includes("coins are per-court, never summed"));
ok("demo senior sums to seniorOwed", (()=>{ const m=src.match(/amount:700_000, paid:60_000/); return !!m; })());
// §7.4 sweep of the two rewritten view bodies
{
  const a=src.indexOf("async function meHoldings"); const b=src.indexOf("/* --- the chain render");
  const region=src.slice(a,b);
  ok("§7.4 clean in me/needs", !/backing|redeem\b|cash out|APR|% ?return|worth|you win|winnings|profit|P&L|\bgain\b/i.test(region));
}

// C3 critic fixes
ok("F1: PullState carries who (3 args)", src.includes("PullState(${s2},${id},${gstr(addr)})"));
ok("F1: detail cache keyed by address", src.includes('slug+"/"+id+"/"+(addr||"")'));
ok("F2: Unstake carries the exact amount", (()=>{ const r=claimables("c",1,{phase:"closed"},{yes:5,no:0,cy:0,cn:0},ME,100); return r.now[0].act[1].amount===5; })());
ok("F3: both sides → two withdraw rows", claimables("c",1,{phase:"settled"},{yes:5,no:3,cy:0,cn:0},ME,100).now.length===2);
ok("F3: both-sides provisional → losing side row survives", claimables("c",1,{phase:"provisional",provisional:0},{yes:5,no:3,cy:0,cn:0},ME,100).now.some(r=>r.label.includes("NO stake")));
ok("F6: vote-settled with failed Verdict read → no winner row", !claimables("c",1,{phase:"settled",crystallized:true,verdict:-1,answer:0,route:"vote",author:"g1a",answerer:"g1b",draw:{w:1,a:1,ans:1,carrot:1},pulls:{winnerPaid:false,authorPaid:true,answererPaid:true}},{yes:5,no:0,cy:5,cn:0},ME,100).now.some(r=>r.label.includes("accuracy")));
ok("F6: undisputed route still falls back to answer", claimables("c",1,{phase:"settled",crystallized:true,verdict:-1,answer:0,route:"undisputed",author:"g1a",answerer:"g1b",draw:{w:1,a:1,ans:1,carrot:0},pulls:{winnerPaid:false,authorPaid:true,answererPaid:true}},{yes:5,no:0,cy:5,cn:0},ME,100).now.some(r=>r.label.includes("accuracy")));
ok("F7: maybe-line needs a carrot pool", src.includes('d.draw.carrot>0) courtHasVoteSettle=true'));
ok("F4: needs clears the detail cache", src.includes("const seq=++needsSeq;\n  DETC = new Map();") || /needsSeq;\s*DETC = new Map/.test(src));
ok("F8: senior scan independent of holdings", src.includes("senior tickets are owed regardless of current holdings"));

ok("D5-critic F2: demo claimDetail carries statusText", src.includes("statusText: statusText(d),"));
console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
