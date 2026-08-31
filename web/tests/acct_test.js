// The account widget: who is signed in, and the basics of what they hold.
//
// WHY IT IS ITS OWN HARNESS. Two of these assertions are about a FAILED read
// rather than a value, and that is the half a browser check would not have
// noticed: a balance that could not be read must never render as a number, least
// of all as 0, because "your coin is gone" and "the node did not answer" are
// opposite facts and only one of them is ever true here.
//
// The payload shapes below are MEASURED against a gnodev chain, not guessed --
// bank/balances answers three different ways and the empty one is the case the
// owner actually hit.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// ------------------------------------------------------------------ the stubs
function node(){ return {textContent:"", innerHTML:"", hidden:false, attrs:{},
  setAttribute(k,v){this.attrs[k]=v}, getAttribute(k){return this.attrs[k]},
  closest(){return null} }; }
let DOM = {};
global.document = { getElementById: id => DOM[id] || null,
                    addEventListener(){}, createRange(){return {selectNodeContents(){}}} };
global.location = { hash: "" };
global.CFG = { mode:"live", addr:"" };
global.isLive = () => CFG.mode === "live";
global.esc = s => String(s).replace(/[&<>"']/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
global.fmtN = n => (n==null?0:Math.round(n)).toLocaleString("en-US");
global.ccSym = slug => slug? "KOURT:"+String(slug).toUpperCase() : "court coin";
global.cc = (n,slug) => ((n||0)/1e6) + " " + ccSym(slug);
global.note = () => {};
let ABCI = null, BAL = null;          // per-test answers
global.abci = async () => { if(typeof ABCI === "function") return ABCI(); return ABCI; };
global.balanceOf = async () => { if(typeof BAL === "function") return BAL(); return BAL; };

eval(slice('function gnotAmt(micro){', '\nfunction shortAddr('));
eval(slice('function acctSlug(){', '/* ======================= the claim composer'));

(async ()=>{
  // ------------------------------------------------------- the slug it reads
  // The court whose coin is worth showing is the one being looked at. Anything
  // that is not a court route has no coin to name, and must not guess one.
  const slugCases = [
    ["#/c/covid?at=join", "covid", "a court page with a query"],
    ["#/c/covid/7",       "covid", "a claim inside a court"],
    ["#/c/my-court",      "my-court", "a hyphenated slug"],
    ["#/me",              "",      "your positions"],
    ["",                  "",      "the bare page"],
    ["#/raw/covid/mod",   "",      "a non-court route that still contains a slug"],
  ];
  for(const [hash, want, what] of slugCases){
    location.hash = hash;
    ok(`slug from ${what}: ${JSON.stringify(want)}`, acctSlug() === want);
  }

  // ------------------------------------------------ the three payload shapes
  // Measured, not assumed. The quotes are part of what the node returns.
  ABCI = '"12345ugnot"';
  ok("a funded balance parses past its own quotes", await gnotOf("g1x") === 12345);
  ABCI = '""';
  ok("a valid address with nothing is a real zero", await gnotOf("g1x") === 0);
  ABCI = '"10000000000000ugnot,5000foo"';
  ok("a second denomination does not confuse the ugnot arm",
     await gnotOf("g1x") === 10000000000000);

  // A THROWN read must PROPAGATE, so the caller can say "could not read".
  // Swallowing it here and returning 0 is the bug this whole harness is about.
  ABCI = () => { throw new Error("node HTTP 500"); };
  let threw = false;
  try { await gnotOf("g1x"); } catch(_){ threw = true; }
  ok("a failed read throws rather than reporting zero", threw);

  // ------------------------------------------------------- the collapsed label
  DOM = {acctwho:node(), acctcar:node(), acctpop:node(), acctbtn:node()};
  CFG.addr = "";
  reflectAccount();
  ok("signed out, the control offers to connect", DOM.acctwho.textContent === "Connect");
  ok("and shows no caret, because there is no menu", DOM.acctcar.hidden === true);

  CFG.addr = "g1n8843p9cm7pyjgvvx34wwdul8t5qjnqzmdwr6e";
  reflectAccount();
  ok("signed in, the address is elided in the middle",
     DOM.acctwho.textContent === "g1n8843…wr6e");
  ok("and the caret appears", DOM.acctcar.hidden === false);

  // ------------------------------------------------------------- the dropdown
  const fill = async (gnot, bal, hash) => {
    DOM = {acctwho:node(), acctcar:node(), acctpop:node(), acctbtn:node()};
    location.hash = hash || "#/c/covid";
    ABCI = gnot; BAL = bal;
    await acctFill();
    return DOM.acctpop.innerHTML;
  };

  let h = await fill('"201700000ugnot"', 5_000_000);
  ok("the full address is shown, not just the elision", h.includes(CFG.addr));
  // EXACTLY, not "contains GNOT somewhere". The `|| h.includes("GNOT")` this
  // replaced was satisfied by any GNOT text at all, including the "could not
  // read" row -- so it would have passed while reporting nothing.
  ok("GNOT is reported to a tenth, not rounded", h.includes("201.7 GNOT"));
  ok("the court's own coin is named by its symbol", h.includes("KOURT:COVID"));
  ok("holding GNOT draws no warning", !h.includes("cannot pay a transaction fee"));
  ok("the way to the full picture is offered", h.includes('href="#/me"'));
  ok("so is disconnecting", h.includes("data-acctoff"));

  // THE AMOUNTS A ROUNDING FORMATTER WOULD MISREPORT. 0.4 GNOT must not print as
  // "0 GNOT": that is the empty wallet's text, and the empty wallet is the state
  // that stops a signature -- so the two must never render the same.
  h = await fill('"400000ugnot"', 1_000_000);
  ok("a fraction of a GNOT keeps two decimals", h.includes("0.40 GNOT"));
  ok("and is not mistaken for an empty wallet", !h.includes("cannot pay a transaction fee"));
  h = await fill('"5000ugnot"', 1_000_000);
  ok("dust falls back to µGNOT rather than rounding to zero", h.includes("5,000 µGNOT"));

  // ZERO IS THE CASE THE OWNER HIT: Adena greys out its own approve button and
  // the page could not say why. Now the number says it.
  h = await fill('""', 0);
  ok("no GNOT is called out where the number is", h.includes("cannot pay a transaction fee"));

  // A FAILED READ IS NOT A ZERO, and must not borrow the zero's warning either.
  h = await fill(()=>{ throw new Error("node down"); }, 5_000_000);
  ok("an unreadable GNOT balance says so", h.includes("could not read"));
  ok("and is never rendered as a number", !/\b0 GNOT\b/.test(h));
  ok("and does not claim you cannot pay a fee", !h.includes("cannot pay a transaction fee"));
  ok("while the coin that DID read still shows", h.includes("KOURT:COVID"));

  // One side failing must not blank the other -- Promise.allSettled, not all().
  h = await fill('"7000000ugnot"', ()=>{ throw new Error("realm read failed"); });
  ok("an unreadable court coin leaves GNOT intact", h.includes("7.00 GNOT"));
  ok("and reports itself as unread", h.includes("could not read"));

  // OFF A COURT ROUTE there is no coin to name, and no empty row for one.
  //
  // COUNTED, not checked for the "KOURT:" prefix. That was vacuous: with no slug
  // ccSym("") returns the generic "court coin", so a row DID render and the
  // prefix test passed anyway. Ablated by rendering the row unconditionally:
  // ALL PASS. The number of rows is the thing that cannot be faked.
  h = await fill('"7000000ugnot"', null, "#/me");
  ok("no court in view means exactly one row, the GNOT one",
     (h.match(/class="arow"/g) || []).length === 1);
  ok("and no coin is named at all", !h.includes("KOURT:") && !h.includes("court coin"));
  ok("GNOT still shows, because it is not a court's", h.includes("7.00 GNOT"));

  // On a court route there are two rows, which is what makes the count above mean
  // something rather than being true of every render.
  h = await fill('"7000000ugnot"', 1_000_000, "#/c/covid");
  ok("a court in view adds its coin as a second row",
     (h.match(/class="arow"/g) || []).length === 2);

  // DEMO MODE never pretends to have read a chain.
  CFG.mode = "demo";
  h = await fill('"1ugnot"', 3_000_000);
  ok("demo says there is no chain rather than showing a GNOT figure",
     h.includes("demo — no chain"));
  CFG.mode = "live";

  console.log(fail? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail?1:0);
})();
