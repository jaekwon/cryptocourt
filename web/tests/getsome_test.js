// "get some →" is OUTSIDE the amount field and does not leave.
//
// WHY IT IS ITS OWN HARNESS. This link used to be built inside the flash — a
// span positioned absolutely within .amtwrap, right-aligned behind the reader's
// own value, removed by a 1800ms timeout. So the only way out of "you hold none"
// sat behind the cursor and was gone before a slow reader reached it, and no
// assertion anywhere said where it lived or how long it lasted. Both of those
// are structural facts about the markup, which is exactly what a source-slice
// harness can hold.
//
// THE TWO PROPERTIES, and they fail in different directions: put back inside the
// wrap it becomes unreachable, and put back on a timer it becomes unfindable.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice } = require("./srcslice");

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// ---------------------------------------------------------------- the markup
global.esc = s => String(s).replace(/[&<>"']/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
global.ccSym = () => "KOURT:COVID";
global.ccSymHtml = slug => `<span class="ccsym">${ccSym(slug)}</span>`;
global.ccText = (n,slug) => ((n||0)/1e6) + " " + ccSym(slug);
global.cc = (m) => (m/1e6) + " KOURT:COVID";
global.btn = (label) => `<button>${label}</button>`;
global.stakeTicketHasActions = () => true;

eval(slice('function stakeTicket(slug,id,d){', '\nfunction focusStakeSide('));

const html = stakeTicket("covid", 7, {phase:"open", answer:null, verdict:null});
ok("the stake ticket renders the link at all", /class="amtget"/.test(html));

// OUTSIDE THE WRAP, and this is the assertion that matters. .amtwrap is
// position:relative and its own children are absolutely positioned inside the
// box, so nesting is the difference between "beside the field" and "behind the
// value".
//
// BY SPAN DEPTH, not by finding a `</span`. The first version of this check took
// indexOf('</span') from the flash and asserted the link came after it — and it
// PASSED with the link nested back inside the wrap, because the link contains an
// aria-hidden span for its arrow and that span's own closing tag was the one the
// search found. The assertion was reading the wrong tag and reported green for
// the one arrangement it existed to reject. Depth cannot be fooled that way:
// walk the tags, and the link has to open at depth 0.
function wrapEnd(h){
  const start = h.lastIndexOf('<span', h.indexOf('id="stakeamtwrap"'));
  if(start < 0) return -1;
  let depth = 0;
  for(let i = start; i < h.length; i++){
    if(h.startsWith('</span', i)){ depth--; if(depth === 0) return i; i += 5; continue; }
    if(h.startsWith('<span', i)){ depth++; i += 4; }
  }
  return -1;
}
const wrapOpen  = html.indexOf('id="stakeamtwrap"');
const linkOpen  = html.indexOf('class="amtget"');
const wrapClose = wrapEnd(html);
ok("the field's wrap is balanced", wrapClose > 0);
ok("the link comes after the field", wrapOpen >= 0 && linkOpen > wrapOpen);
ok("and OUTSIDE the wrap, not nested in it", wrapClose > 0 && linkOpen > wrapClose);

// To the RIGHT is the row's job, not a hand-placed offset: .ticket .argrow is
// flex with a gap, so a sibling lands beside the field and stays put when the
// balance grows. A left/right/position rule on .amtget would mean somebody went
// back to placing it by hand.
const css = slice('.amtget{', '.amtget[hidden]');
ok("the link is not hand-positioned", !/position\s*:\s*absolute/.test(css));
ok("nor does it set its own left/right", !/(^|[;{\s])(left|right)\s*:/.test(css));
ok("the ticket row is the flex that places it",
   /\.ticket \.argrow\{[^}]*display:flex/.test(src));

// ------------------------------------------------------- shown when held is 0
// A tiny DOM, only as much as fillStakeBalance touches.
function node(){ return {textContent:"", hidden:undefined, dataset:{}, classList:{
  s:new Set(), add(c){this.s.add(c)}, remove(c){this.s.delete(c)}, contains(c){return this.s.has(c)} },
  addEventListener(){}, }; }
let DOM = {};
global.document = { getElementById: id => DOM[id] || null };
global.CFG = { addr:"g1abc", mode:"live" };
let BAL = 0;
global.balanceOf = async () => BAL;

eval(slice('async function fillStakeBalance(slug){', '\nasync function fillTicketPulls('));

(async ()=>{
  const run = async (micro) => {
    DOM = {stakebal:node(), stakeamt:node(), stakeamtwrap:node(), stakeget:node()};
    BAL = micro;
    await fillStakeBalance("covid");
    return DOM;
  };

  // HOLDING NONE: the way out is on screen from the balance read, before the
  // reader presses anything. That is the change — it used to take a refused
  // click to find out there was anywhere to go.
  let d = await run(0);
  ok("holding none shows the link", d.stakeget.hidden === false);
  ok("and the balance still reads as none", d.stakebal.classList.contains("none"));

  // HOLDING SOME: hidden, because it is not an offer anyone needs.
  d = await run(201_700_000);
  ok("holding coin hides the link", d.stakeget.hidden === true);
  ok("and the balance is not marked none", !d.stakebal.classList.contains("none"));

  // The boundary: one unit is holding some.
  d = await run(1);
  ok("one unit counts as holding some", d.stakeget.hidden === true);

  // ----------------------------------------------------- and it is not on a timer
  // The flash still expires — it is a warning, and a warning that stays becomes
  // furniture. The LINK must not be in that sentence. Read from bad()'s source:
  // if it ever builds or clears an anchor again, the timer owns the way out.
  const bad = slice('      const bad = () => {', '      if(!raw || !isFinite(coins)');
  ok("the refusal path never builds a link", !/createElement\("a"\)/.test(bad));
  ok("nor touches the persistent one", !/stakeget|amtget/.test(bad));
  ok("the flash alone is what expires", /_flash\s*=\s*setTimeout/.test(bad));
  ok("and the refusal still says something", /textContent\s*=\s*held === 0\?/.test(bad));

  // The input listener clears the flash on the next keystroke. Same rule: it may
  // not take the link with it, or typing a bad number twice would hide the fix.
  const inp = slice('document.addEventListener("input", (e) => {', '\ndocument.addEventListener("error"');
  ok("correcting the field does not hide the link", !/stakeget|amtget/.test(inp));

  console.log(fail? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail?1:0);
})();
