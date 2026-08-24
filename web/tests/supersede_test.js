// chainAssociations' second half: the re-filing edges the realm now holds.
//
// WHY IT IS ITS OWN HARNESS. supersede.gno went on chain with the entrypoints
// wired to buttons, which is half a feature: writable and not readable is the
// same defect as the claim body was in reverse — that one could be read and
// never written, and looked finished from every angle but the one that mattered.
// These assertions are the other angle.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.CFG = { mode:'live', chainid:'dev' };
global.isLive = ()=> CFG.mode==='live';

// The two reads chainAssociations makes, answered per test.
let ARGS = null, SUP = null, CALLS = [];
global.one = async expr => {
  CALLS.push(expr);
  if(/ClaimAssociations/.test(expr)){ if(ARGS===null) throw new Error("no such read"); return ARGS; }
  if(/ClaimSupersedes/.test(expr)){ if(SUP===null) throw new Error("no such read"); return SUP; }
  throw new Error("unexpected "+expr);
};
global.unesc = x => x;
global.gstr = s => JSON.stringify(String(s));

eval(slice('async function chainAssociations(', '\nfunction curationFor('));

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

(async ()=>{
  // `of:X` — this claim re-files X, so X is the one superseded BY THIS. `by:Y,Z`
  // — those re-file this one. The direction is the whole point: getting it
  // backwards renders a claim as its own predecessor.
  ARGS = "out:;in:"; SUP = "of:5;by:9,11";
  let rows = await chainAssociations("orem", 7);
  ok("`of` reads as superseded-by-this",
     rows.some(r=>r[0]===5 && r[1]==="superseded by this"));
  ok("`by` reads as supersedes",
     rows.some(r=>r[0]===9 && r[1]==="supersedes") && rows.some(r=>r[0]===11 && r[1]==="supersedes"));
  ok("and nothing else is invented", rows.length===3);

  // Empty halves are the common case and must produce no rows at all, not a row
  // with a NaN id — the realm answers "of:;by:" for most claims alive.
  ARGS = "out:;in:"; SUP = "of:;by:";
  rows = await chainAssociations("orem", 7);
  ok("an empty edge set draws nothing", rows === null || rows.length===0);

  // Both kinds ride together, one round trip each.
  ARGS = "out:2:s;in:3:c"; SUP = "of:5;by:";
  CALLS = [];
  rows = await chainAssociations("orem", 7);
  ok("associations survive alongside re-filings",
     rows.some(r=>r[1]==="supported by this") && rows.some(r=>r[1]==="contradicts")
     && rows.some(r=>r[1]==="superseded by this"));
  ok("two reads, not more", CALLS.length===2);

  // A REALM THAT PREDATES EITHER READ still gets the other. Dropping a claim's
  // associations because a newer entrypoint is missing would make deploying
  // this overlay against an older realm strictly worse than not deploying it.
  ARGS = "out:2:s;in:"; SUP = null;
  rows = await chainAssociations("orem", 7);
  ok("no ClaimSupersedes: associations still render",
     rows && rows.length===1 && rows[0][1]==="supported by this");
  ARGS = null; SUP = "of:5;by:";
  rows = await chainAssociations("orem", 7);
  ok("no ClaimAssociations: re-filings still render",
     rows && rows.length===1 && rows[0][1]==="superseded by this");
  ARGS = null; SUP = null;
  rows = await chainAssociations("orem", 7);
  ok("neither read: no chain rows at all", rows === null);

  // Demo mode must not point a live read at sample ids.
  CFG.mode='demo';
  ok("demo mode reads nothing", (await chainAssociations("orem", 7)) === null);
  CFG.mode='live';

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
