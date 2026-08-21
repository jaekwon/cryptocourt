// Stake-index harness: the client reads one holder's positions instead of probing
// every claim.
//
// WHY THIS EXISTS. The me-page used to find positions by probing four reads per claim id
// over a window of the newest SCAN_DEPTH = 100 claims per court, then telling the holder
// "older positions and older pulls are not found either" — so on a bigger court a holder
// could not see their own position at all. The realm keys an address-first index now, so
// the page asks once. The regression this pins hardest is the SHAPE: that live mode no
// longer walks claims to find positions.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
eval(slice('function parseStaked(', 'const COMMIT_LANE'));

let fail = 0;
function ok(what, cond){ if(cond){ console.log("ok: "+what); } else { fail++; console.log("FAIL: "+what); } }

// This fixture is a string the REALM produced, asserted verbatim in
// TestStakingIsIndexedAndTheReadReportsLiveStake: two sides of claim 1, one of claim 2.
const REAL = "c:1:0:3000000000;c:1:1:1000000000;c:2:0:2000000000";
const P = parseStaked(REAL);
ok("every entry is parsed", P.length===3);
ok("claim, side and live stake survive", P[0].id===1 && P[0].side===0 && P[0].stake===3000000000);
ok("the NO side is its own entry", P[1].id===1 && P[1].side===1 && P[1].stake===1000000000);
ok("a missing read parses to nothing", parseStaked(null).length===0 && parseStaked("").length===0);
ok("a malformed record is skipped, not half-read", parseStaked("c:1:0").length===0);
ok("a foreign record type is ignored", parseStaked("q:d:1:1:5;c:9:0:7").length===1);
// A withdrawn position stays listed at zero — its conviction may still be owed.
ok("a zero stake is kept, not dropped", parseStaked("c:4:0:0")[0].stake===0);

const G = stakedByClaim(P);
ok("both sides collapse onto one claim row", G.length===2);
ok("the row carries each side separately",
  G[0].id===1 && G[0].yes===3000000000 && G[0].no===1000000000);
ok("a one-sided claim leaves the other side zero",
  G[1].id===2 && G[1].yes===2000000000 && G[1].no===0);
ok("a NO-only position does not land in yes",
  (()=>{ const r=stakedByClaim(parseStaked("c:5:1:900"))[0]; return r.yes===0 && r.no===900; })());

// ---- the wiring, which is the actual fix ----
ok("live mode asks the index for the holder's own positions",
  src.includes('StakedPage(${gstr(slug)},${gstr(addr)},0,0)'));
ok("and asks how many there are, so partial can be told from complete",
  src.includes('StakedSize(${gstr(slug)},${gstr(addr)})'));
ok("both reads are caught, so a failure degrades instead of throwing",
  /StakedPage\(\$\{gstr\(slug\)\},\$\{gstr\(addr\)\},0,0\)`\)\.catch\(/.test(src));

// THE REGRESSION THAT MATTERS: live mode must not walk claims to find positions.
ok("the me-page no longer scans a claim window in live mode",
  !src.includes('const depth = isLive()? (parseInt(QP.scan||"",10)||SCAN_DEPTH) : 0;\n    const {ids, total} = await claimIdsFor(slug, depth)'));
ok("demo mode still uses the sample scan", src.includes('ids = (await claimIdsFor(slug, 0)'));
// The note now counts the holder's own positions, not a claim window.
ok("the scan note speaks of positions rather than the newest N claims",
  src.includes('of your positions in ${esc(sl)}'));
ok("and no longer says older positions cannot be found",
  !src.includes('older positions and older pulls are not found either'));

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
