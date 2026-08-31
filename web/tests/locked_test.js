// A LOCKED page ignores a chain saved in the browser.
//
// WHY IT IS ITS OWN HARNESS. Measured on kourt.xyz: the deployed page was reading
// http://127.0.0.1:26657 and printing it into the gnokey command it offers, while
// the wallet was correctly on the deployed chain and therefore refused to
// establish. The cause was a saved config from an earlier visit to the repo copy
// on the same origin — cleanCfg starts from CFG_DEFAULTS and lets stored values
// override them — and LOCKED hides the source panel, so nothing on screen could
// show it or undo it.
//
// That is the exact hazard the LOCKED comment names, "a way to point a production
// page at somebody else's node and then read the result as if it were this
// court", arriving through localStorage rather than through the panel it guards.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// The block under test, run twice: once as the repo copy and once as a deploy.
// LOCKED and CFG_DEFAULTS are substituted because deploy.sh rewrites those two
// lines, which is what makes this worth testing on both settings.
const cleanFn = slice('function cleanCfg(c){', '\nconst store = {');
const loadBlk = slice('let stored = {};', '\nconst saveCfg =');

function load(locked, saved, defaults){
  let written = null;
  const sandbox = {
    LOCKED: locked,
    CFG_DEFAULTS: defaults,
    store: { get: () => JSON.stringify(saved), set: (k,v) => { written = v; }, del(){} },
    document: { querySelector: () => null },
  };
  const body = "return (function(){ " + cleanFn + "\n" + loadBlk
             + "\n; return {CFG: CFG, written: written}; })();";
  const fn = new Function("LOCKED","CFG_DEFAULTS","store","document","written", body);
  const out = fn(sandbox.LOCKED, sandbox.CFG_DEFAULTS, sandbox.store, sandbox.document, null);
  return {cfg: out.CFG, written};
}

const DEPLOYED = {mode:"live", rpc:"https://rpc.kourt.xyz", gnoweb:"https://gnoweb.kourt.xyz", chainid:"kourt-1"};
// Exactly what was in the owner's browser.
const STALE = {mode:"live", rpc:"http://127.0.0.1:26657", chainid:"dev",
               addr:"g1w746drdmenjdg0ll38dltjt7kkgtq5lmsmghcg", theme:"dark"};

// ------------------------------------------------------------------ deployed
{
  const {cfg} = load(true, STALE, DEPLOYED);
  ok("a deployed page keeps its own RPC", cfg.rpc === "https://rpc.kourt.xyz");
  ok("...and its own chain id", cfg.chainid === "kourt-1");
  ok("...and its own gnoweb", cfg.gnoweb === "https://gnoweb.kourt.xyz");
  // THE READER'S PREFERENCES ARE NOT THE CHAIN. Dropping these would sign them
  // out and reset their theme on every visit, which is a different bug.
  ok("but the reader's account survives", cfg.addr === STALE.addr);
  ok("...and so does their theme", cfg.theme === "dark");
}

// The stale key must be REWRITTEN, or the override returns on the next load as
// soon as anything calls saveCfg with a fresh object.
{
  const {written} = load(true, STALE, DEPLOYED);
  ok("the stale key is rewritten, not merely ignored in memory", written !== null);
  const back = JSON.parse(written || "{}");
  ok("...with the deployed chain in it", back.rpc === "https://rpc.kourt.xyz" && back.chainid === "kourt-1");
  ok("...and without the local node", !/127\.0\.0\.1/.test(written || ""));
}

// ------------------------------------------------------------- the repo copy
// Choosing a node is exactly what the unlocked copy is FOR, so the same saved
// config must still win there. Without this arm the fix above could have been
// "always ignore stored config", which would break local development.
{
  const REPO = {mode:"demo", rpc:"http://127.0.0.1:26657", gnoweb:"https://gno.land", chainid:"dev"};
  const {cfg} = load(false, {mode:"live", rpc:"http://127.0.0.1:26750", chainid:"kourtdev"}, REPO);
  ok("the repo copy still honours a chosen node", cfg.rpc === "http://127.0.0.1:26750");
  ok("...and a chosen chain id", cfg.chainid === "kourtdev");
  ok("...and a chosen mode", cfg.mode === "live");
}

// A deployed page with NOTHING saved must simply be itself.
{
  const {cfg} = load(true, {}, DEPLOYED);
  ok("a first visit to a deployed page uses the deployed values",
     cfg.rpc === "https://rpc.kourt.xyz" && cfg.chainid === "kourt-1" && cfg.mode === "live");
}

// A saved config naming a DIFFERENT public node is the case the LOCKED comment
// is actually about — somebody else's node read as if it were this court.
{
  const {cfg} = load(true, {mode:"live", rpc:"https://rpc.example.com", chainid:"evil-1"}, DEPLOYED);
  ok("nor can it be pointed at another chain entirely",
     cfg.rpc === "https://rpc.kourt.xyz" && cfg.chainid === "kourt-1");
}

console.log(fail? `\n${fail} FAILURES` : "\nALL PASS");
process.exit(fail?1:0);
