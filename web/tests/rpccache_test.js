// The read cache in abci().
//
// WHY THIS HARNESS. A cache is invisible when it works and invisible when it is
// wrong: the page draws either way, and the wrong version draws numbers from
// before the reader's own transaction. Nothing in a screenshot distinguishes
// them. So the properties are pinned here — one fetch per question, a refusal
// never remembered, and a clear that actually empties it.
//
// The measurement that justifies the TTL is in the comment beside it: at five
// seconds returning to a court cost 70 of its 80 reads again, at thirty it costs
// one. This harness holds the correctness half.
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
// A harness that dies mid-run must not look like one that finished: without
// this, an assertion that CRASHES prints nothing at all and the summary below
// never runs.
let DONE = false;
process.on("exit", () => { if(!DONE){ console.log("\nDIED BEFORE FINISHING"); process.exitCode = 1; } });
process.on("unhandledRejection", e => { console.log("FAIL: unhandled rejection:", e && e.message); process.exit(1); });
let fail = 0;
const ok = (n, c) => { if(!c){ fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

global.CFG = {rpc:"http://node"};
global.b64 = s => Buffer.from(String(s)).toString("base64");
global.unb64 = s => Buffer.from(String(s), "base64").toString();

// a fetch that counts, and can be told to fail
let calls = 0, mode = "ok";
global.fetch = async () => {
  calls++;
  if(mode === "http") return {ok:false, status:503};
  return {ok:true, json: async () => mode === "realm"
    ? {result:{response:{ResponseBase:{Error:{}, Log:"name Nope not declared"}}}}
    : {result:{response:{Data: Buffer.from("v"+calls).toString("base64")}}}};
};

// The clock is the input this cache turns on, so it is controlled rather than
// waited out: a harness that slept 30 seconds would be a harness nobody runs.
let NOWMS = 1_000_000;
const RealDate = Date;
global.Date = { now: () => NOWMS };

eval(slice("const RPC_TTL_MS =", "const qeval  ="));

(async () => {
  // const inside an eval does not escape that eval's scope — the functions do,
  // and they close over it — so the number is read from the source directly.
  const TTL = Number(/const RPC_TTL_MS = (\d+);/.exec(src)[1]);
  ok("the TTL is the measured one, not the five seconds that saved nothing", TTL === 30000);

  // ---- one fetch per question ----------------------------------------------
  calls = 0;
  const a = await abci("vm/qeval", "Q1");
  const b = await abci("vm/qeval", "Q1");
  ok("the same question is asked of the node once", calls === 1);
  ok("and both callers get the same answer", a === b && a === "v1");
  await abci("vm/qeval", "Q2");
  ok("a different question is a different entry", calls === 2);
  // The KEY is path AND data: vm/qeval and vm/qrender of the same string are two
  // different questions, and a key that dropped the path would answer one with
  // the other.
  await abci("vm/qrender", "Q1");
  ok("path is part of the key", calls === 3);

  // ---- callers in the same tick share ONE request ---------------------------
  calls = 0;
  const both = await Promise.all([abci("vm/qeval","T"), abci("vm/qeval","T")]);
  ok("two callers in one tick share a single request", calls === 1);
  ok("and both are handed the same value", both[0] === both[1]);

  // ---- it expires ------------------------------------------------------------
  calls = 0;
  await abci("vm/qeval", "E");
  NOWMS += TTL - 1;
  await abci("vm/qeval", "E");
  ok("inside the window it is not re-asked", calls === 1);
  NOWMS += 2;
  await abci("vm/qeval", "E");
  ok("past the window it is asked again", calls === 2);

  // ---- a refusal is never remembered -----------------------------------------
  // A node that was briefly unreachable must not answer for the next half
  // minute: the reader's retry has to be a real one.
  calls = 0; mode = "http";
  await abci("vm/qeval", "F").then(() => ok("an HTTP failure rejects", false),
                                   () => ok("an HTTP failure rejects", true));
  mode = "ok";
  // Explicitly, because a REMEMBERED rejection makes this await throw rather
  // than return — which crashes the harness instead of naming the fault, and a
  // crash is not a test result.
  let after = null, threw = false;
  try{ after = await abci("vm/qeval", "F"); }catch(_){ threw = true; }
  ok("and is not cached — the retry reaches the node",
     !threw && calls === 2 && after === "v2");

  calls = 0; mode = "realm";
  await abci("vm/qeval", "G").then(() => ok("a realm refusal rejects", false),
                                   () => ok("a realm refusal rejects", true));
  mode = "ok";
  let threw2 = false;
  try{ await abci("vm/qeval", "G"); }catch(_){ threw2 = true; }
  ok("a realm refusal is not cached either", !threw2 && calls === 2);

  // ---- clearing ---------------------------------------------------------------
  calls = 0;
  await abci("vm/qeval", "C");
  chainCacheClear();
  await abci("vm/qeval", "C");
  ok("chainCacheClear empties it", calls === 2);

  // ---- and it is cleared where it must be -------------------------------------
  // Both are invisible failures: the first draws the reader's own transaction as
  // not having happened, the second answers about a node the page no longer reads.
  const sign = slice("async function adenaSign", "\ndocument.addEventListener");
  ok("a landed transaction clears the cache",
     (sign.match(/chainCacheClear\(\)/g) || []).length >= 1);
  ok("...including at the repaint that follows it",
     /chainCacheClear\(\);\s*render\(\)/.test(sign.replace(/\s+/g, " ")));
  ok("changing the node clears it too",
     /store\.set\("cc\.cfg"[\s\S]{0,400}chainCacheClear\(\)/.test(src));

  global.Date = RealDate;
  DONE = true;
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
