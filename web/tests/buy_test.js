// B2 quote-math harness: extract the curve block + panel builders from the live
// file, cross-check curveQuote against a brute-force reference of the realm's
// semantics (largest Δ with ceil-cost ≤ X), and render the panel both modes.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');

const { slice } = require("./srcslice");
// curve block through the recompute wiring (stop before courtBody)
const curve = slice('const CURVE_D', 'function courtBody');
// helpers the panel needs
// cc() became TWO lines in round 16 when the unit changed from a generic
// "CC" to the court's own KOURT:SLUG, and it gained ccSym() as a dependency.
// Slicing to the first newline used to capture the whole function; it now
// truncates it mid-body.
const helpers = slice('function fmtN(', 'function ccSym(')
  + slice('function ccSym(', 'function ugnot(')
  // The voice-share line uses the site's one small-percentage spelling, which
  // is declared further down the file than these two.
  + slice('function pctText(', '\n}') + '\n}';
// esc()
// the gas pair the wallet and the printed command share — sliced, never retyped
const gasDecls = slice('const GAS_WANTED', 'const CFG_DEFAULTS');
const escFn = slice('function esc(', '\n');
// tx/btn/cliCmd
const btnBlock = slice('function tx(func', 'document.addEventListener("click"');

// ---- stubs ----
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo', gnoweb:'https://gno.land', rpc:'http://127.0.0.1:26657', chainid:'dev' };
global.PKG = 'gno.land/r/kourt/kourtv2';
global.isLive = ()=> CFG.mode==='live';

let code = gasDecls + escFn + helpers + btnBlock + curve;
code = code.replace('let BUYQ=null, BUYCTX=null;', 'var BUYQ=null, BUYCTX=null;');
code = code.replace(/document\.addEventListener\("(input|change)"[^\n]*\n/g, '');
eval(code);

// ---- reference implementation: literal walk (largest Δ with ceil-cost ≤ X) ----
const D = 1000000000n;
const cost = (s0,s1)=> (s1*s1-s0*s0 + 2n*D - 1n)/(2n*D);
function refQuote(s0, X){
  // walk up from s0 until cost exceeds X (only feasible for small Δ)
  let s1 = s0;
  while(cost(s0, s1+1n) <= X) s1++;
  return s1 - s0;
}

let fail = 0;
const ok = (name, cond)=>{ if(!cond){ fail++; console.log("FAIL:", name); } else console.log("ok:", name); };

// 1) exactness vs brute force on assorted small sends across curve positions
const positions = [0n, 1n, 999n, 118491100000n, 461168601842000n];
const sends = [1n, 117n, 118n, 119n, 1000n, 123457n, 100000000n];
let agree = true;
for(const s0 of positions){
  for(const X of sends){
    const q = curveQuote(s0, 1e9, X);
    const got = q? q.units : 0n;
    // brute-force reference only when the walk is small; large fills are
    // checked by the realm invariants below (no overspend / no underfill)
    if(got <= 20000n){
      const want = refQuote(s0, X);
      if(got !== want){ agree=false; console.log("  mismatch s0="+s0+" X="+X+" got="+got+" want="+want); }
    }
    if(q && q.units>0n){
      // realm invariants: cost ≤ X; one more unit would exceed X (unless at cap)
      if(cost(s0, s0+q.units) > X){ agree=false; console.log("  overspend s0="+s0+" X="+X); }
      if(s0+q.units < 461168601842738n && cost(s0, s0+q.units+1n) <= X){ agree=false; console.log("  underfill s0="+s0+" X="+X); }
      if(q.refund !== X - cost(s0, s0+q.units)){ agree=false; console.log("  refund wrong s0="+s0+" X="+X); }
    }
  }
}
ok("quote == brute-force reference on "+(positions.length*sends.length)+" cases", agree);

// 2) orem demo: 100 GNOT at s0 = supply−emitted
const S0 = 118500000000 - 8900000;
const q = curveQuote(S0, 118500000000, 100000000n);
ok("orem 100 GNOT mints ~0.84 CC", q.units>800000n && q.units<900000n);
ok("orem avg ≈ 118.5 µGNOT/unit", q.avg>118 && q.avg<119);
ok("orem priceAfter ≥ now(118)", q.priceAfter>=118);
ok("orem cost+refund == X", q.cost + q.refund === 100000000n);

// 3) dust send refuses (price 118 → 117 µGNOT mints nothing)
const dust = curveQuote(S0, 118500000000, 117n);
ok("dust send → units 0 (realm would panic)", dust.units===0n);

// 4) parseGnot: string-exact decimals
ok("parseGnot('100') = 1e8", parseGnot("100")===100000000n);
ok("parseGnot('2.5') = 2,500,000", parseGnot("2.5")===2500000n);
ok("parseGnot('0.000001') = 1", parseGnot("0.000001")===1n);
ok("parseGnot('1.2345678') rejected (7 dp)", parseGnot("1.2345678")===null);
ok("parseGnot('abc') rejected", parseGnot("abc")===null);
ok("parseGnot('0') → curveQuote null", curveQuote(S0,1e9,parseGnot("0"))===null);

// 5) cap clamp: near the cap a huge send fills to cap only
const nearCap = 461168601842738n - 5n;
const qc = curveQuote(nearCap, 1e9, 10n**15n);
ok("cap clamp: units ≤ 5", qc.units<=5n);

// 6) determinism + no float drift on the money path
const q2 = curveQuote(S0, 118500000000, 100000000n);
ok("deterministic", q2.units===q.units && q2.cost===q.cost);

// 7) panel renders in demo mode with rows + ack + inert button
const s = {price:118, supply:118500000000, emitted:8900000, minted:S0};
const html = joinPanel("orem", s);
ok("panel: input present", html.includes('id="buyamt"'));
ok("panel: five labels", ["You burn","You receive","Average price you pay","Price after this","Your voice share"].every(l=>html.includes(l)));
// round 61: the Buy button had to be scrolled to. What a reader needs BEFORE
// pressing is one row — what they get; the rest is a receipt and belongs under
// the button. Lock the order, or the receipt creeps back above it row by row.
ok("panel: one row above the button", (()=>{
  const q = curveQuote(s.minted, s.supply, 100000000n);
  return (buyRowsHtml(q, s.price, "orem").match(/class="line"/g)||[]).length === 1;
})());
ok("panel: button precedes the receipt", html.indexOf('id="buyactions"') < html.indexOf('id="buyrows2"'));
ok("panel: receipt rows sit below the button", ["Average price you pay","Price after this","Your voice share"]
     .every(l => html.indexOf(l) > html.indexOf('id="buyactions"')));
ok("panel: what you get sits above the button", html.indexOf("You receive") < html.indexOf('id="buyactions"'));
ok("panel: ack sentence", html.includes("cannot be sold back to the court"));
// Tags stripped to a SPACE, not to nothing: the coin symbol is wrapped for
// colour now, so "0.87<span ...>KOURT:X</span>" would otherwise join up.
const plain = h => String(h).replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");
ok("panel: button restates output", /Get 0\.8\d KOURT:[A-Z]+/.test(plain(html)));
ok("panel: demo sample note", html.includes("Sample data — computed from the demo court"));
// DEMO CARRIES NO COMMAND LINE ANY MORE. It used to: the CLI toggle rendered
// beside every button in every mode, so sample data came with a runnable
// gnokey line against a real network — the exact trap the inert button was
// added to prevent, sitting on the control next to it. The command is a live
// affordance now, in the sign-help dialog, and demo mode has neither.
ok("panel: demo offers no runnable command for sample data",
   !html.includes("--send") && !html.includes("gnokey") && !html.includes("data-cli"));
ok("panel: fineprint worst case", html.includes("private buyer, and there may not be one"));
ok("panel: demo button inert", html.includes('data-inert="1"'));
ok("panel: no banned words", !/backing|redeem|profit|APR/i.test(html));

// 8) live mode: gated anchor + staleness note; and the no-quote fallback
CFG.mode = 'live';
const htmlL = joinPanel("orem", s);
ok("live: anchor gated until ack", htmlL.includes('data-needack="1"') && htmlL.includes('aria-disabled="true"'));
// ...and the concrete send moved here with it, which is where it was always
// true: this is the mode where the amount is a real amount.
ok("live: CLI --send concrete", htmlL.includes("--send 100000000ugnot"));
// A gated button must still be PRESSABLE. Disabling it swallows the click, and
// the click is the only thing that says why it will not go through.
ok("live: the gate does not disable the button",
   !/data-needack="1"[^>]*\sdisabled/.test(htmlL));
ok("live: staleness caveat", htmlL.includes("fewer units than shown, never more"));
const htmlF = joinPanel("orem", {price:118, supply:118500000000, emitted:8900000, minted:null});
ok("live fallback: price+supply kv, no computed rows", htmlF.includes("No quote") && !htmlF.includes('id="buyrows"') && htmlF.includes("coin price"));
ok("live fallback: CLI placeholder send", htmlF.includes("--send AMOUNTugnot"));


// ---- round 60: critic-fix assertions ----
ok("F4: parseGnot caps at int64 max", parseGnot("9223372036854.775807")===9223372036854775807n);
ok("F4: parseGnot rejects beyond int64", parseGnot("9223372036854.775808")===null && parseGnot("100000000000000000000")===null);
// The refund row moved BELOW the Buy button with the other three disclosures —
// what a buyer needs before pressing is how much they get; the rest is a receipt.
// So it is asked for with after=true, which is the half that now holds it. The
// exact-digits point is unchanged: toLocaleString on a BigInt, never Number.
ok("F4: refund row uses exact BigInt digits", buyRowsHtml({x:10n**18n, units:1000000n, cost:10n**18n-9007199254740993n, refund:9007199254740993n, avg:1, priceAfter:1, share:0}, 1, "orem", true).includes("9,007,199,254,740,993"));
CFG.mode='live';
const gated = buyActionsHtml("orem", null);
// THE PROPERTY, not the old shape. This asserted "an <a> with no href", which
// was how the gate used to stop a middle-click or open-in-new-tab from routing
// around the acknowledgement. The control is a <button> now, so that is
// structural — and "no href" alone would pass on markup with no action at all.
// What has to hold is that the gated control is a real, pressable action that
// the handler will refuse.
ok("F2: the gated action is a button the handler can refuse",
   /<button class="btn primary"[^>]*data-needack="1"/.test(gated)
   && /<button class="btn primary"[^>]*data-act="1"/.test(gated)
   && !gated.includes("href="));
const htmlF2 = joinPanel("orem", {price:118, supply:118500000000, emitted:8900000, minted:null});
ok("F3: fallback keeps the ack checkbox", htmlF2.includes('id="buyack"'));
ok("F3: fallback buy gated until ack", (()=>{
  const m = htmlF2.match(/<button class="btn primary"[^>]*>/);
  return m && m[0].includes("data-needack") && m[0].includes("data-act")
         && !m[0].includes("href=") && !/\sdisabled/.test(m[0]);
})());
ok("F3: BUYCTX noquote set", BUYCTX && BUYCTX.noquote===true);
CFG.mode='demo';

// ---- round 62: the tx has to carry a ceiling a Buy fits inside ----
//
// Measured on a live node, no write to this realm fits inside the 10,000,000-gas
// ceiling this page printed: SetCourtDesc, one string field, costs 20,087,222,
// and `Buy` costs 27,954,243 plus a 217,500ugnot storage deposit
// (`gnokey maketx call -func Buy -args covid -send 100000000ugnot
//  -gas-wanted 900000000 -simulate only -broadcast`). ~20M is the fixed cost of
// loading the realm. The command could not execute anything.
//
// It is NOT why Adena greys out Approve: Adena honours a dApp-supplied fee only
// for session messages and simulates every /vm.m_call itself. The fields are
// still sent, because a wallet that does honour them must not get 10M.
const BUY_GAS_MEASURED = 27954243;
// the eval'd slice declares these with const, which does not escape its own
// eval scope — so read the same two lines out of the source directly.
const GAS_WANTED = Number(src.match(/const GAS_WANTED = (\d+)/)[1]);
const GAS_FEE_UGNOT = Number(src.match(/const GAS_FEE_UGNOT = (\d+)/)[1]);
ok("gas: the ceiling clears the measured cost of a Buy, with headroom",
   GAS_WANTED > BUY_GAS_MEASURED * 1.5);
ok("gas: the fee is exactly the floor for that ceiling, not a ugnot more",
   GAS_FEE_UGNOT === GAS_WANTED / 1000);   // genesis price: 1ugnot/1000gas
ok("gas: the signed tx carries both",
   /gasFee: GAS_FEE_UGNOT, gasWanted: GAS_WANTED/.test(src));
{
  const cmd = cliCmd("Buy", {slug:"orem"}, "100000000ugnot");
  ok("gas: the printed command offers the same pair the wallet signs",
     cmd.includes("--gas-wanted " + GAS_WANTED) && cmd.includes("--gas-fee " + GAS_FEE_UGNOT + "ugnot"));
}

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
