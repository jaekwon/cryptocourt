// The buy form survives a re-render, and is not inherited across courts.
//
// WHY IT IS ITS OWN HARNESS. This is a bug the owner hit twice on the live site
// and described as "it connected and disappeared". Connecting a wallet calls
// render(), which replaces main.innerHTML, so the amount they had typed and the
// acknowledgement they had ticked were discarded. The resume then found the Buy
// button and clicked it — and the button REFUSED, because the tick it needed had
// just been thrown away. Two correct-looking fixes (re-find the live node, await
// the render) both landed before this one, and neither could work while the form
// reset underneath them.
//
// So the property is not "the resume clicks something". It is "the form the
// reader filled in is still there to be resumed INTO".
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// ---- stubs: only what the three functions touch ----
global.parseGnot = v => { const m=/^([0-9]+)(?:\.([0-9]{1,6}))?$/.exec(String(v||"").trim());
  return m? BigInt(m[1])*1000000n + BigInt((m[2]||"0").padEnd(6,"0")) : null; };
let RECOMPUTED = 0, REFRESHED = 0;
global.recomputeBuy = () => { RECOMPUTED++; };
global.refreshBuyActions = () => { REFRESHED++; };

let code = slice('let BUYQ=null, BUYCTX=null;', 'function buyActionsHtml(')
         + slice('function rememberBuyAmt(el){', '\ndocument.addEventListener("input"')
         + slice('function rememberBuyAck(el){', '\ndocument.addEventListener("change"');
code = code.replace('let BUYQ=null, BUYCTX=null;', 'var BUYQ=null, BUYCTX=null;')
           .replace('let BUYFORM =', 'var BUYFORM =');
eval(code);

// ---------------------------------------------------------------- remembering
BUYCTX = {slug:"covid"};
rememberBuyAmt({value:"250.5"});
ok("the typed amount is remembered", BUYFORM.amt === "250.5");
ok("...and the field still recomputes its quote", RECOMPUTED === 1);

rememberBuyAck({checked:true});
ok("the acknowledgement is remembered", BUYFORM.ack === true);
ok("...and the buttons still refresh", REFRESHED === 1);
ok("...without discarding the amount", BUYFORM.amt === "250.5");

// THE ORDER THAT ACTUALLY BIT: tick, THEN adjust the figure, then press Buy. An
// amount edit must not clear the tick. Nothing asserted this direction at first,
// and the ablation that clears ack inside rememberBuyAmt passed happily.
rememberBuyAmt({value:"300"});
ok("editing the amount keeps the acknowledgement", BUYFORM.ack === true);
ok("...and takes the new figure", BUYFORM.amt === "300");
rememberBuyAmt({value:"250.5"});   // back, so the assertions below read as before

// Unticking is remembered too — a form that only remembers the tick would let a
// re-render re-arm a button the reader had deliberately disarmed.
rememberBuyAck({checked:false});
ok("unticking is remembered as well", BUYFORM.ack === false);
ok("...and still not at the amount's expense", BUYFORM.amt === "250.5");

// ------------------------------------------------------------ per court, not global
rememberBuyAck({checked:true});
ok("the same court gets its form back",
   buyFormFor("covid").amt === "250.5" && buyFormFor("covid").ack === true);
// THE INTERESTING HALF: a different court must NOT inherit a tick acknowledging
// that a DIFFERENT coin cannot be sold back. That is a consent, not a preference.
const other = buyFormFor("flu");
ok("another court starts clean", other.amt === "" && other.ack === false);
ok("...and asking did not overwrite the remembered one",
   BUYFORM.slug === "covid" && BUYFORM.ack === true);

// No context yet (panel never drawn) must not throw or invent a slug.
BUYCTX = null;
const before = JSON.stringify(BUYFORM);
rememberBuyAmt({value:"9"});
ok("an edit with no panel context changes nothing", JSON.stringify(BUYFORM) === before);

// ---------------------------------------- the BUTTON agrees with the CHECKBOX
// The bug this closes: the checkbox was drawn from BUYFORM and the button's gate
// was read from the live DOM, which does not exist while joinPanel is building a
// string. So a re-render drew a ticked box beside a gated button, and pressing it
// complained about a tick that was plainly on screen. One source of truth, or they
// disagree exactly when it matters -- right after a transaction lands.
{
  const acts = slice('function buyActionsHtml(slug, q){', '\n/* ---------------- the court record');
  ok("the gate reads the remembered form", /const acked = !!buyFormFor\(slug\)\.ack;/.test(acts));
  ok("...and never the live checkbox", !/getElementById\("buyack"\)/.test(acts));
  // Both must come from the same place, which is what makes them agree.
  const panel0 = slice('function joinPanel(slug, s){', '\nfunction recomputeBuy(');
  ok("the checkbox reads it too", /const ackAttr = form\.ack\?/.test(panel0)
     && /const form = buyFormFor\(slug\)/.test(panel0));
}

// ------------------------------------------------------- the panel restores them
// Source-level, because joinPanel builds a template string rather than a DOM.
// Both are asserted on the ATTRIBUTE, not on the variable name, so deleting the
// interpolation from the markup fails even though the variable still exists.
const panel = slice('function joinPanel(slug, s){', '\nfunction courtBody(');
// BOTH BRANCHES, COUNTED. joinPanel draws the tick twice — once on the quoted
// arm and once on the no-quote arm — so asserting "it appears" passed with one of
// them reverted. Found by an ablation that only replaced the first occurrence.
ok("the checkbox is drawn checked when it was ticked, on BOTH arms",
   (panel.match(/id="buyack"\$\{ackAttr\}/g) || []).length === 2);
ok("...from the remembered form, not from a fresh default",
   /const ackAttr = form\.ack\?/.test(panel) && /buyFormFor\(slug\)/.test(panel));
ok("the amount field is drawn with the remembered value",
   /value="\$\{esc\(amtVal\)\}"/.test(panel));
ok("...and the quote is computed from that same figure",
   /curveQuote\(minted, s\.supply, amtMicro==null\? 100000000n : amtMicro\)/.test(panel));
// The µGNOT echo under the field must agree with the field. It read a hardcoded
// 1e8 before, so a restored 250.5 would have shown "= 100,000,000 µGNOT".
ok("...as is the microGNOT echo beneath it", !/id="buyugnot">= \$\{fmtN\(1e8\)\}/.test(panel));

console.log(fail? `\n${fail} FAILURES` : "\nALL PASS");
process.exit(fail?1:0);
