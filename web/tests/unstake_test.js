// Unstake is offered for a side only when that side is actually held.
//
// WHY THIS HARNESS. Both unstake buttons used to be drawn unconditionally, so
// the first thing a new reader met on an open claim was four buttons of which
// two could only fail — and they failed in the WALLET, with a realm panic,
// after the extension had already woken and asked for a signature. Nothing in
// the page said so; the ticket looked complete.
//
// It has two halves and they break in different directions. The markup half:
// the sides must ship hidden and addressable, because a fill that cannot find
// them silently offers nothing to a reader who does hold a position. The fill
// half: it must unhide exactly the held sides — unhide too many and the old bug
// is back, too few and unstaking becomes impossible from the page.
//
// THE SELECTOR IS THE SUBTLE PART and it is asserted here on purpose. btn()'s
// demo branch emits an inert button with NO data-func, so a fill that looked
// its sides up by function name would match nothing in the sample and, worse,
// go on matching everything on the live page — passing every test written
// against live markup. Three earlier fills on this page made that mistake.
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
let fail = 0, DONE = false;
process.on("exit", () => { if(!DONE){ console.log("\nDIED BEFORE FINISHING"); process.exitCode = 1; } });
const ok = (n, c) => { if(!c){ fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

global.esc = s => String(s).replace(/[&<>"']/g, c =>
  ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
global.ccSym = () => "KOURT:COVID";
global.cc = m => (m/1e6).toFixed(1) + " KOURT:COVID";
global.btn = label => `<button class="btn">${label}</button>`;
global.stakeTicketHasActions = () => true;

eval(slice("function stakeTicket(slug,id,d){", "\nfunction focusStakeSide("));

// ------------------------------------------------------------- the markup ---
const html = stakeTicket("covid", 7, {phase:"open", answer:null, verdict:null});

ok("both unstake sides ship wrapped and hidden",
   /<span data-unstake="0" hidden><button class="btn">Unstake YES<\/button><\/span>/.test(html) &&
   /<span data-unstake="1" hidden><button class="btn">Unstake NO<\/button><\/span>/.test(html));

// AND THE STAKE SIDES ARE NOT WRAPPED. Staking is what the ticket is for and it
// is offered to everyone; wrapping those too would hide the whole ticket from
// every first-time reader, which is the same bug with the sign flipped.
ok("staking is still offered unconditionally",
   /<button class="btn">Stake YES<\/button>/.test(html) &&
   /<button class="btn">Stake NO<\/button>/.test(html) &&
   !/data-unstake="[01]"[^>]*><button class="btn">Stake /.test(html));

ok("the ticket is addressable by the id the fill looks for",
   /id="stake-ticket"/.test(html));

// --------------------------------------------------------------- the fill ---
// A DOM small enough to read: the two wraps, each with the button inside it.
function makeTicket(){
  const mk = side => ({
    dataset: {unstake: side}, hidden: true,
    btn: {html: "Unstake " + (side==="0"?"YES":"NO"),
          insertAdjacentHTML(_, s){ this.html += s; }},
    querySelector(sel){ return sel === ".btn" ? this.btn : null; },
  });
  const sides = [mk("0"), mk("1")];
  return {sides, querySelectorAll: sel => sel === "[data-unstake]" ? sides : []};
}
let TICKET = makeTicket();
global.document = { getElementById: id => id === "stake-ticket" ? TICKET : null };
global.CFG = {addr: "g1reader"};
let POS = {yes: 0, no: 0}, asked = [];
global.positionOf = async (slug, id, who) => {
  asked.push([slug, id, who]);
  if(POS instanceof Error) throw POS;
  return POS;
};

eval(slice("async function fillUnstakeSides(", "\nasync function fillStakeBalance("));

(async () => {
  const shown = () => TICKET.sides.filter(s => !s.hidden).map(s => s.btn.html);

  TICKET = makeTicket(); POS = {yes: 20_000_000, no: 0}; asked = [];
  await fillUnstakeSides("covid", 7);
  ok("one read, and it asks for this reader's position on this claim",
     asked.length === 1 && asked[0][0] === "covid" && asked[0][1] === 7 && asked[0][2] === "g1reader");
  ok("a reader holding YES is offered YES and only YES",
     shown().length === 1 && shown()[0].startsWith("Unstake YES"));
  ok("and the button says what taking it back returns",
     shown()[0].includes("20.0 KOURT:COVID"));

  TICKET = makeTicket(); POS = {yes: 0, no: 12_000_000};
  await fillUnstakeSides("covid", 7);
  ok("a reader holding NO is offered NO and only NO",
     shown().length === 1 && shown()[0].startsWith("Unstake NO"));

  TICKET = makeTicket(); POS = {yes: 5_000_000, no: 1};
  await fillUnstakeSides("covid", 7);
  ok("a reader holding both is offered both", shown().length === 2);

  // THE CASE THE BUG WAS: nothing staked, nothing offered.
  TICKET = makeTicket(); POS = {yes: 0, no: 0};
  await fillUnstakeSides("covid", 7);
  ok("a reader holding nothing is offered nothing", shown().length === 0);

  // ---- and it stays hidden rather than guessing -----------------------------
  TICKET = makeTicket(); POS = {yes: 20_000_000, no: 0}; asked = [];
  global.CFG = {addr: ""};
  await fillUnstakeSides("covid", 7);
  ok("no wallet: nothing is asked and nothing is offered",
     asked.length === 0 && shown().length === 0);
  global.CFG = {addr: "g1reader"};

  TICKET = makeTicket(); POS = new Error("name PositionOf not declared");
  await fillUnstakeSides("covid", 7);
  ok("a failed read leaves the sides hidden, not open", shown().length === 0);

  TICKET = makeTicket(); POS = {yes: "-3", no: null};
  await fillUnstakeSides("covid", 7);
  ok("a negative or absent holding is not a holding", shown().length === 0);

  // a claim page with no ticket on it at all — the settled and closed routes
  TICKET = null; POS = {yes: 20_000_000, no: 0}; asked = [];
  global.document = { getElementById: () => null };
  await fillUnstakeSides("covid", 7);
  ok("no ticket on the page: the fill asks nothing", asked.length === 0);

  DONE = true;
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
