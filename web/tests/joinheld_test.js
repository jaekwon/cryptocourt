// The court page says what you already hold.
//
// WHY IT EXISTS. Reported after the first real buy on kourt.xyz: "when i actually
// did buy some, there's no indication ultimately." The Join panel had refreshed
// every CHAIN figure — supply, price, the voice share a further buy would earn —
// and said nothing about the reader's own position. So the one question somebody
// has after pressing Buy, "did it work and what do I own", was answered nowhere on
// the page they bought from. It was in the account menu and on /me, both of which
// you have to know to look at.
//
// THE FAILURE CASE IS THE POINT OF THE HARNESS. This is the row a person reads to
// find out whether their money arrived, so a wrong number here is worse than no
// row at all — an unreadable balance must leave the row hidden, never show 0.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}

// The coin name is markup now (the gold bar), so compare the TEXT of it. That
// text is "Kourt:META", not "KOURT:META": the bar carries the word as written
// and the colon is present but visually hidden, which is the whole point of
// rendering it as elements rather than a string.
const strip = h => String(h||"").replace(/<[^>]*>/g, "");
// ccSymHtml escapes the slug it renders, so esc has to exist here too.
global.esc = t => String(t).replace(/[&<>"']/g, c =>
  ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

function node(){ return {textContent:"", hidden:true}; }
let DOM = {};
global.document = { getElementById: id => DOM[id] || null };
global.CFG = { addr:"g1w746drdmenjdg0ll38dltjt7kkgtq5lmsmghcg", mode:"live" };
global.ccSym = slug => slug? "KOURT:"+String(slug).toUpperCase() : "court coin";
global.fmtN = n => (n==null?0:Math.round(n)).toLocaleString("en-US");
// The real cc(), because the row's text is what a reader acts on.
eval(slice('function ccSymHtml(', '\nfunction ugnot('));
let BAL = null;
global.balanceOf = async () => { if(typeof BAL === "function") return BAL(); return BAL; };

eval(slice('async function fillJoinHeld(slug){', '\nfunction recomputeBuy('));

(async ()=>{
  const run = async (bal, addr) => {
    DOM = {joinheld:node(), joinheldv:node()};
    BAL = bal;
    CFG.addr = addr === undefined ? "g1w746drdmenjdg0ll38dltjt7kkgtq5lmsmghcg" : addr;
    await fillJoinHeld("meta");
    return DOM;
  };

  // THE EXACT BUY THAT PROMPTED THIS: 447,213,595 units of KOURT:META.
  let d = await run(447_213_595);
  ok("a real holding is shown", d.joinheld.hidden === false);
  ok("...as coin, not raw units", strip(d.joinheldv.innerHTML) === "447.2 Kourt:META");

  // Zero is shown too: on a court somebody has just failed to buy into, "none
  // yet" answers the same question a number does, and answers it better.
  d = await run(0);
  ok("holding nothing is stated, not hidden", d.joinheld.hidden === false);
  // A FIGURE, NOT A PHRASE. Every other row in the Join panel is a number and a
// unit; "none yet" made this one read as a different kind of thing.
ok("...as a figure in the same shape as the rows under it",
   strip(d.joinheldv.innerHTML) === "0.00 Kourt:META");

  // A FAILED READ LEAVES THE ROW HIDDEN. Showing 0 here would tell somebody their
  // purchase vanished.
  d = await run(()=>{ throw new Error("node down"); });
  ok("an unreadable balance shows no row", d.joinheld.hidden === true);
  ok("...and writes no number", d.joinheldv.textContent === "");

  // Same for a nonsense answer from the chain.
  for(const junk of [null, undefined, NaN, "abc"]){
    d = await run(junk);
    ok(`a ${String(junk)} balance shows no row`, d.joinheld.hidden === true);
  }

  // Not connected: nothing to say, and no read attempted.
  let asked = 0;
  d = await run(()=>{ asked++; return 5; }, "");
  ok("signed out, the row stays hidden", d.joinheld.hidden === true);
  ok("...and the chain is not asked at all", asked === 0);

  // ---------------------------------------------------------------- the markup
  const panel = slice('function joinPanel(slug, s){', '\nfunction recomputeBuy(');
  ok("the slot ships hidden, so it never renders empty",
     /id="joinheld" hidden/.test(panel));
  ok("...above the buy ticket, not below it",
     panel.indexOf('id="joinheld"') < panel.indexOf('${body}'));
  // Called from the court page's chain-backed fills, and only when live: demo has
  // no address to read for.
  ok("the court page fills it when live",
     /if\(isLive\(\)\) fillJoinHeld\(slug\);/.test(src));

  console.log(fail? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail?1:0);
})();
