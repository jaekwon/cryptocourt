// The map's SELECTION BEHAVIOUR, exercised against a real element tree.
//
// WHY THIS EXISTS, and it is an admission. map_test.js pinned the click rules by
// GREPPING mountMap's source for `ev.preventDefault(); select({kind:"claim"` and
// friends. Every one of those passed while the feature was broken in three ways
// the owner found by using it: clicking a claim while a folder card was open did
// nothing, the folder card stayed, and no claim card ever appeared. A grep proves
// a line was written. It cannot prove the line runs, or that the state it changes
// reaches the panel.
//
// So this mounts the real mountMap against a small DOM shim and clicks things.
// The shim is deliberately tiny — enough tree, classList, dataset, listeners and
// bubbling for the handlers under test, and nothing else. jsdom would be a
// dependency, and this repo's harnesses are standalone node scripts with none.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}

// ---- the shim ------------------------------------------------------------
let NODES = [];
class El {
  constructor(tag, attrs){
    this.tag = tag; this.attrs = attrs || {}; this.children = []; this.parent = null;
    this.dataset = {}; this._cls = new Set((this.attrs.class||"").split(/\s+/).filter(Boolean));
    for(const k of Object.keys(this.attrs)) if(k.startsWith("data-")) this.dataset[k.slice(5)] = this.attrs[k];
    this.id = this.attrs.id || "";
    this._listeners = {};
    this.classList = {
      add: c => this._cls.add(c), remove: c => this._cls.delete(c),
      contains: c => this._cls.has(c),
      toggle: (c, on) => { const want = on===undefined ? !this._cls.has(c) : !!on;
                           want ? this._cls.add(c) : this._cls.delete(c); return want; },
    };
    NODES.push(this);
  }
  get className(){ return [...this._cls].join(" "); }
  set innerHTML(html){
    for(const d of this.descendants()) NODES.splice(NODES.indexOf(d), 1);
    this.children = []; this._html = html;
    for(const el of parse(html)){ el.parent = this; this.children.push(el); }
  }
  get innerHTML(){ return this._html || ""; }
  get textContent(){ return (this._html || "").replace(/<[^>]*>/g, ""); }
  descendants(){ return this.children.flatMap(c => [c, ...c.descendants()]); }
  matches(sel){
    return sel.split(",").map(s=>s.trim()).some(s => {
      const m = /^([.#]?)([\w-]+)(?:\[([\w-]+)="([^"]*)"\])?$/.exec(s);
      if(!m) return false;
      const [, kind, name, attr, val] = m;
      const base = kind==="." ? this._cls.has(name) : kind==="#" ? this.id===name : this.tag===name;
      return base && (!attr || this.attrs[attr]===val);
    });
  }
  closest(sel){ let n = this; while(n){ if(n.matches && n.matches(sel)) return n; n = n.parent; } return null; }
  querySelectorAll(sel){ return this.descendants().filter(d => d.matches(sel)); }
  querySelector(sel){ return this.querySelectorAll(sel)[0] || null; }
  addEventListener(t, fn){ (this._listeners[t] = this._listeners[t] || []).push(fn); }
  focus(){}
  // A real viewport width, so the level-of-detail line can be exercised: it is
  // what decides whether a claim shows its sentence or only "#17 settled".
  get clientWidth(){ return this.tag==="svg" ? (global.VIEWPORT||660) : 0; }
  getScreenCTM(){ return null; }
  setAttribute(k,v){ this.attrs[k]=v; }
  getAttribute(k){ return this.attrs[k]; }
  // bubbling: the handler under test lives on an ancestor and reads ev.target
  click(extra){
    const ev = Object.assign({target:this, button:0, defaultPrevented:false,
      preventDefault(){ this.defaultPrevented = true; }, stopPropagation(){}}, extra||{});
    for(let n=this; n; n=n.parent) for(const fn of (n._listeners.click||[])) fn(ev);
    return ev;
  }
}
function parse(html){
  const out = [], stack = [];
  const re = /<(\/?)([\w-]+)((?:\s+[\w-]+="[^"]*")*)\s*(\/?)>/g;
  let m;
  while((m = re.exec(html))){
    const [, close, tag, attrsRaw, selfClose] = m;
    if(close){ stack.pop(); continue; }
    const attrs = {};
    for(const a of attrsRaw.matchAll(/([\w-]+)="([^"]*)"/g)) attrs[a[1]] = a[2];
    const el = new El(tag, attrs);
    const parent = stack[stack.length-1];
    if(parent){ el.parent = parent; parent.children.push(el); } else out.push(el);
    if(!selfClose && !/^(rect|circle|polyline|polygon|line|path|input|br)$/.test(tag)) stack.push(el);
  }
  return out;
}
const byId = {};
global.document = {
  getElementById: id => byId[id] || null,
  addEventListener: ()=>{},
  createElement: t => new El(t, {}),
};
// A default read stub. Nothing above should reach the chain — demo mode never
// does — and if something starts to, the arms below say so rather than the
// harness dying on an undefined global.
global.STRAY_READS = [];
global.one = expr => { global.STRAY_READS.push(expr); return Promise.resolve(""); };
global.gstr = x => JSON.stringify(String(x));
global.unesc = x => x;
global.requestAnimationFrame = fn => { fn(); return 0; };
global.cancelAnimationFrame = ()=>{};
global.DOMPoint = class { constructor(x,y){ this.x=x; this.y=y; }
                          matrixTransform(){ return {x:this.x, y:this.y}; } };
global.CFG = { mode:'demo' };
global.isLive = ()=> false;
global.esc = s => String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;")
  .replace(/>/g,"&gt;").replace(/"/g,"&quot;");
global.safeInline = s => global.esc(s);
// THE REAL phaseClass AND statusPill, not a stub. mapSelCard renders the shared
// pill now, and a stub here would let the card and the pill drift with no harness
// noticing — which is how the card came to drop the verdict side in the first place.
eval(slice('function phaseClass(', 'function statusPill('));
eval(slice('function statusPill(', 'function docketRow('));
// ...and the real body renderer, for the same reason: the card renders it.
eval(slice('function claimBody(', '/* ==='));
// claimExhibits lives inside that same region deliberately: the card renders a
// claim's statement and its evidence together, so a harness that has one and
// not the other is testing half a card.
global.fmtN = n => String(n);

eval(slice('const MAPK', '/* The join panel').replace('const MAPK','var MAPK'));
eval(slice('function mountMap(', '/* Folder page'));

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// ---- a court with two folders and three claims ---------------------------
const data = {
  // Fauci carries a chain folder id, Origins does not — one of each, because a
  // curation folder has no description on the chain to ask for and must not ask.
  folders:[{name:"Fauci", claims:[1,2], folders:[], path:"0", fid:7},
           {name:"Origins", claims:[3], folders:[], path:"1"}],
  all:[1,2,3],
  claims:{1:{title:"A claim about the record.", statusText:"settled — every stake withdraws"},
          2:{title:"Another claim, filed later.", statusText:"open — stake YES or NO"},
          3:{title:"A third, in another folder.", statusText:"open — stake YES or NO"}},
  relations:[{from:1,to:3,type:"bears",stance:"contradicts"}],
  courtName:"Test Court", linkFolders:true,
};
let box, panel;
function mount(focus){
  box = new El("div", {id:"mapbox"});
  panel = new El("div", {id:"mapsel"});
  byId.mapbox = box; byId.mapsel = panel;
  mountMap("covid", data, focus===undefined? null : focus);
}
// the zoom controls mountMap binds to
for(const id of ["mz-slider","mz-in","mz-out","mz-fit","mt-titles","mt-ids"]) byId[id] = new El("button",{id});
// the panel's own close button is looked up by id after each paint
Object.defineProperty(byId, "msel-x", {get(){ return panel.querySelector("#msel-x"); }});

mount();

ok("the empty column explains the map is interactive", /Click a claim/.test(panel.innerHTML));

/* THE TITLES MUST BE ABOVE THE LEVEL-OF-DETAIL LINE WHEN THE MAP OPENS.
   `.mapsvg.far .mtitle{display:none}` hides every title below 7px of rendered
   type, which is right for a fitted view of a big docket and wrong for the view
   the map now opens on. Reported as "none of the claim titles show, just says
   #17 settled". */
ok("the map opens with titles legible, not just ids",
   !box.querySelector("svg").classList.contains("far"));

const folderA = () => box.querySelector('.mfold-a[data-fid="0"]');
const claimA = id => box.querySelector(`.mnode-a[data-id="${id}"]`);

ok("the map drew folder anchors", !!folderA());
ok("the map drew claim anchors", !!claimA(1) && !!claimA(2) && !!claimA(3));

// ---- THE THREE BUGS THE OWNER FOUND --------------------------------------
folderA().click();
ok("clicking a folder opens the folder card", /Fauci/.test(panel.innerHTML));
ok("and the folder card is a FOLDER card", /Open folder page/.test(panel.innerHTML));

const ev = claimA(2).click();
ok("clicking a claim while a folder card is open is intercepted", ev.defaultPrevented);
ok("...and the folder card is REPLACED, not left open", !/Open folder page/.test(panel.innerHTML));
ok("...by the claim's own card", /Open claim page/.test(panel.innerHTML));
ok("...naming that claim", /#2/.test(panel.innerHTML));

// a claim clicked from nothing selected
mount();
claimA(1).click();
ok("clicking a claim from a clean map opens its card", /Open claim page/.test(panel.innerHTML)
   && /#1/.test(panel.innerHTML));
ok("and the node is marked selected", claimA(1).classList.contains("selected"));

// folder then folder
folderA().click();
ok("a folder click after a claim swaps back", /Open folder page/.test(panel.innerHTML));
ok("and the claim is no longer marked", !claimA(1).classList.contains("selected"));

// clearing
const x = panel.querySelector("#msel-x");
ok("the card offers a close control", !!x);
if(x) x.click();
ok("closing returns the hint", /Click a claim/.test(panel.innerHTML));

// ---- the view follows the selection --------------------------------------
{
  // mountMap holds cx/cy privately, so the observable is the viewBox it writes.
  const vb = () => (box.querySelector("svg").getAttribute("viewBox")||"").split(" ").map(Number);
  mount();
  const before = vb();
  claimA(3).click();
  const after = vb();
  const mid = v => [v[0]+v[2]/2, v[1]+v[3]/2];
  ok("selecting a node moves the view", mid(before)[0]!==mid(after)[0] || mid(before)[1]!==mid(after)[1]);
  ok("and lands on that node", (()=>{
    const L2 = mapLayout(data, "titles"), n = L2.nodes.find(x=>x.id===3);
    const [mx,my] = mid(after);
    return Math.abs(mx-n.cx) < 1 && Math.abs(my-n.cy) < 1;
  })());
  ok("titles stay legible after centring",
     !box.querySelector("svg").classList.contains("far"));
}

/* THE VIEW GLIDES, IT DOES NOT TELEPORT. centreOn used to assign cx/cy/z and
   paint the next frame, so selecting a node in the outer ring replaced the whole
   drawing between one frame and the next — "jarring", and worse than cosmetic:
   the motion is what tells a reader that the thing they clicked is the thing now
   in the middle. Landing on target was already asserted above; these arms say it
   ARRIVES rather than appears.
   The rAF stub here is synchronous, so the whole flight happens inside click() —
   which is also the case the frame cap in glideTo exists for. */
{
  mount();
  const svg = box.querySelector("svg");
  const seen = [], set = svg.setAttribute.bind(svg);
  svg.setAttribute = (k,v)=>{ if(k==="viewBox") seen.push(v); return set(k,v); };
  claimA(3).click();
  const mid = v => { const a=v.split(" ").map(Number); return [a[0]+a[2]/2, a[1]+a[3]/2]; };
  const L3 = mapLayout(data,"titles"), n3 = L3.nodes.find(x=>x.id===3);
  ok("the view is stepped over many frames, not written once", seen.length > 3);
  ok("and the steps are distinct views", new Set(seen).size >= 3);
  ok("the first step has not arrived yet",
     Math.abs(mid(seen[0])[0]-n3.cx) > 0.5 || Math.abs(mid(seen[0])[1]-n3.cy) > 0.5);
  ok("the last step lands exactly on the node", (()=>{
     const [mx,my]=mid(seen[seen.length-1]);
     return Math.abs(mx-n3.cx)<0.001 && Math.abs(my-n3.cy)<0.001; })());
  ok("a glide never outlives the reader taking over",
     /const schedule=\(\)=>\{ stopTween\(\);/.test(src));
  ok("reduced motion gets the jump instead",
     /if\(still \|\| reduce\)\{ cx=tx; cy=ty; z=tz; schedule\(\); return; \}/.test(src));
}

/* THE OPENING ZOOM IS A RENDERED SIZE, NOT A RULE ABOUT THE DRAWING. "Frame the
   court and ring 1" says nothing about how big that comes out on screen, and the
   map went from a 640px box to the whole viewport — the same z that showed a
   claim at 208px in the box showed it at 441px full screen, in 21px type. */
{
  const nodeW = MAPK.node.titles.w;
  const shown = vw => {
    global.VIEWPORT = vw;
    mount();
    const vb = box.querySelector("svg").getAttribute("viewBox").split(" ").map(Number);
    return nodeW * vw / vb[2];          // rendered width of a claim box, px
  };
  const narrow = shown(660), wide = shown(1400), huge = shown(1900);
  ok("a claim renders at a usable size on a narrow viewport", narrow > 120 && narrow < 340);
  ok("...and does not balloon when the map goes full screen", wide > 120 && wide < 340);
  ok("...or on a very wide one", huge > 120 && huge < 340);
  /* NOT "all three agree" — that was the first version of this check and it
     asked for something the geometry cannot give. Measured 224/300/300: on a
     660px viewport the CORE ITSELF is the binding constraint, because no zoom
     both shows the court with its first ring and renders those nodes at 300px in
     that width. Showing the ring is the more important half, so the narrow case
     accepts a smaller node. What must hold is the band, which is what a reader
     actually feels. */
  ok("no viewport is zoomed so far in that a node dominates the screen",
     Math.max(narrow, wide, huge) <= 340);
  global.VIEWPORT = 660;
}

/* THE MAP'S OWN BUCKET WAS INERT, and the card for it had been written. When
   some claims are filed and others are not, the map draws a pseudo folder for
   the leftovers, and mapFolderCard has a branch that says "the map's own bucket
   — the court has filed no folder for these" instead of offering a folder page.
   That branch could not run. The click handler selects on `.mfold-a`, which is
   the class on the ANCHOR a folder gets when it has a page to link to — and the
   pseudo folder has no page, so it was never wrapped in one. A visible box, on a
   map whose whole point is that you can click things, that did nothing.
   It is worth a DOM test rather than a grep for the same reason the rest of this
   file exists: every assertion about the card's contents passed, because the
   card's code was right. Nothing reached it. */
{
  const mixed = {
    folders:[{name:"Filed", claims:[1], folders:[], path:"0"}],
    all:[1,2],
    claims:{1:{title:"A filed claim.",   statusText:"open — stake YES or NO"},
            2:{title:"An unfiled claim.", statusText:"open — stake YES or NO"}},
    relations:[], courtName:"Test Court", linkFolders:true,
  };
  box = new El("div", {id:"mapbox"});
  panel = new El("div", {id:"mapsel"});
  byId.mapbox = box; byId.mapsel = panel;
  mountMap("covid", mixed, null);

  // fid 1 is the pseudo folder: the real one is 0, the bucket is appended after.
  const bucket = box.querySelector('g[data-fid="1"]')
              || box.querySelector('a[data-fid="1"]');
  ok("the map draws a bucket for the claims in no folder", !!bucket);
  if(bucket){
    bucket.click();
    ok("clicking the bucket opens a card, like any other folder",
       /mapsel-h/.test(panel.innerHTML) && !/Click a claim/.test(panel.innerHTML));
    ok("...and that card is the bucket's own, not a folder page offer",
       /own bucket/.test(panel.innerHTML) && !/Open folder page/.test(panel.innerHTML));
    ok("...and it lists what is in it", /#2/.test(panel.innerHTML));
  }
}

/* A RELATION ON A CLAIM'S CARD IS A WAY THERE, not a number. The card tallied
   "asserts: 1 contradicts" and stopped, naming a count rather than a claim. The
   rows are the same `.mapsel-c` buttons a folder card uses, so the handler that
   already binds them needed nothing — but "the handler already binds them" is
   exactly the sort of claim that turned out to be false for the map's own
   bucket, so it is clicked here rather than asserted from the source. */
{
  mount();
  claimA(1).click();
  const row = panel.querySelector('.mapsel-c');
  ok("a claim's card offers its relation as something to select", !!row);
  ok("...naming the claim at the other end, not this one",
     !!row && row.dataset.go === "3");
  if(row){
    row.click();
    ok("...and selecting it moves the card to that claim",
       /#3/.test(panel.innerHTML) && /Open claim page/.test(panel.innerHTML));
    ok("...and marks it on the map", claimA(3).classList.contains("selected"));
  }
}

/* THE LEGEND KEY FOLLOWS THE DRAWING. A claim filed in two folders is drawn
   once and gets a muted dashed spoke to the other folder — which looks like a
   relation and is not one, so it needs a key. It needs one only when there IS
   one: an entry explaining a line nobody drew is the same lie the other way
   round. The answer comes from the layout rather than from a second pass over
   the data, so it cannot disagree with what was drawn. */
{
  byId["mlg-also"] = new El("span", {id:"mlg-also"});
  const claims2 = {1:{title:"Filed once.",  statusText:"open — stake YES or NO"},
                   2:{title:"Filed twice.", statusText:"open — stake YES or NO"}};

  const single = {folders:[{name:"A", claims:[1,2], folders:[], path:"0"}],
                  all:[1,2], claims:claims2, relations:[],
                  courtName:"Test Court", linkFolders:true};
  box = new El("div", {id:"mapbox"}); panel = new El("div", {id:"mapsel"});
  byId.mapbox = box; byId.mapsel = panel;
  mountMap("covid", single, null);
  ok("the 'also filed here' key stays hidden when no claim is filed twice",
     byId["mlg-also"].hidden === true);

  const twice = {folders:[{name:"A", claims:[1,2], folders:[], path:"0"},
                          {name:"B", claims:[2],   folders:[], path:"1"}],
                 all:[1,2], claims:claims2, relations:[],
                 courtName:"Test Court", linkFolders:true};
  box = new El("div", {id:"mapbox"}); panel = new El("div", {id:"mapsel"});
  byId.mapbox = box; byId.mapsel = panel;
  mountMap("covid", twice, null);
  ok("...and appears once a claim is filed in two folders",
     byId["mlg-also"].hidden === false);
}

/* THE CARD'S TEXT, AND THE THREE WAYS FETCHING IT ON DEMAND GOES WRONG: reading
   in demo mode where there is no chain, re-reading text already held, and landing
   a slow answer in whatever card happens to be open by then. The reads are stubbed
   as promises this harness resolves BY HAND, so the last one is a real out-of-order
   arrival and not a simulation of one.
   Async, hence the tail moved in here — the rest of the file is synchronous. */
(async () => {
  const settle = () => new Promise(r=>setImmediate(r));
  // demo first: there is no chain to ask, and the card must not pretend otherwise
  mount();
  claimA(1).click();
  await settle();
  ok("demo mode reads nothing for the card", global.STRAY_READS.length === 0);
  ok("and shows no body block", !/claimbody/.test(panel.innerHTML));

  global.isLive = ()=> true;
  const gate = [];
  global.one = expr => new Promise(res => gate.push({expr, res}));
  const answer = (re, text) => { const g = gate.find(x=>re.test(x.expr)); if(g) g.res(text); return !!g; };

  mount();
  claimA(1).click();
  await settle();
  ok("a claim card asks for its body", gate.some(g=>/ClaimBody\("covid",1\)/.test(g.expr)));
  ok("and asks for exactly one thing", gate.length === 1);
  ok("the card is painted before the read lands", /A claim about the record/.test(panel.innerHTML));
  answer(/ClaimBody/, "Settles on the released chain.\n\nFiled because <b>quotation</b> matters.");
  await settle();
  ok("the body appears when the read lands", /class="claimbody"/.test(panel.innerHTML));
  ok("...split into its paragraphs", (panel.innerHTML.match(/<p>/g)||[]).length >= 2);
  ok("...and escaped, never re-interpreted as markup",
     /&lt;b&gt;quotation&lt;\/b&gt;/.test(panel.innerHTML) && !/<b>quotation<\/b>/.test(panel.innerHTML));

  const before = gate.length;
  claimA(2).click(); claimA(1).click();          // away and back
  await settle();
  ok("a body already held is not read again",
     gate.filter(g=>/ClaimBody\("covid",1\)/.test(g.expr)).length === 1);
  ok("...while a new claim is", gate.length > before);

  // THE TWO CACHES COVER DIFFERENT CASES, so they get an arm each — ablating
  // either alone otherwise reveals nothing, because the other still holds.
  // In flight: clicked twice before the answer lands, still one read.
  mount();
  delete data.claims[2].body;
  gate.length = 0;
  claimA(2).click();
  claimA(1).click();
  claimA(2).click();
  await settle();
  ok("a read still in flight is not issued twice",
     gate.filter(g=>/ClaimBody\("covid",2\)/.test(g.expr)).length === 1);
  answer(/ClaimBody\("covid",2\)/, "");
  await settle();
  // Across a remount — the titles/ids toggle rebuilds the map and `asked` with
  // it — an empty answer is still an answer and must not be re-asked.
  mount();
  gate.length = 0;
  claimA(2).click();
  await settle();
  ok("and a remount does not re-ask what the data already holds", gate.length === 0);

  // the race the guard exists for: #1 answered only after #3 is the open card
  mount();
  // Both bodies must be UNREAD or there is no race to observe: claim 1's was
  // cached by the arms above, so the reads would never be issued and the arm
  // would pass on an empty stage.
  delete data.claims[1].body; delete data.claims[3].body;
  gate.length = 0;
  claimA(1).click();
  await settle();
  claimA(3).click();
  await settle();
  ok("both reads are genuinely outstanding", gate.length === 2);
  answer(/ClaimBody\("covid",1\)/, "The body of claim one.");
  answer(/ClaimBody\("covid",3\)/, "The body of claim three.");
  await settle();
  ok("a late read lands in its own card, not the open one",
     /body of claim three/i.test(panel.innerHTML) && !/body of claim one/i.test(panel.innerHTML));

  // folders: the moderators' words for what belongs in here
  mount();
  gate.length = 0;
  folderA().click();
  await settle();
  ok("a folder card asks the chain for its description",
     gate.some(g=>/FolderDesc\("covid",7\)/.test(g.expr)));
  answer(/FolderDesc/, "What NIAID funded, and what his office wrote.");
  await settle();
  ok("and shows it once it lands", /mapsel-d/.test(panel.innerHTML)
     && /What NIAID funded/.test(panel.innerHTML));

  // the pair: a curation folder has no chain id, so there is nothing to ask
  mount();
  gate.length = 0;
  box.querySelector('.mfold-a[data-fid="1"]').click();
  await settle();
  ok("a folder with no chain id asks nothing", gate.length === 0);
  ok("...and its card simply has no description", !/mapsel-d/.test(panel.innerHTML));

  /* ARRIVING FROM A FOLDER PAGE. #/c/<slug>/map?ffocus=<path> has to land on the
     folder the reader was already looking at — SELECTED, with its card up, not
     merely centred: they chose the folder, and its value is what is filed in it.
     Matched on path, not on the drawing index that data-fid carries, because the
     index is an artefact of layout order and moves when the tree changes. */
  {
    global.isLive = ()=> false;
    /* PATHS THAT ARE NOT THE INDICES. The shared fixture numbers its folders
       "0" and "1", which are also their positions in the layout — so matching on
       the drawing index instead of the path passes by coincidence, and an
       ablation that broke exactly that moved only one assertion. Here the paths
       are 4 and 9, so index-matching cannot land on the right folder at all. */
    const pdata = JSON.parse(JSON.stringify(data));
    pdata.folders[0].path = "4";   // Fauci,   drawn at index 0
    pdata.folders[1].path = "9";   // Origins, drawn at index 1
    const mountF = p => { box = new El("div", {id:"mapbox"}); panel = new El("div", {id:"mapsel"});
                          byId.mapbox = box; byId.mapsel = panel;
                          mountMap("covid", pdata, null, p); };
    mountF("9");
    ok("a folder focus opens that folder's card", /Origins/.test(panel.innerHTML));
    ok("...and not the folder sharing that drawing index", !/Fauci/.test(panel.innerHTML));

    mountF("4");
    ok("a different path opens a different folder", /Fauci/.test(panel.innerHTML));

    mountF("99");
    ok("an unknown path selects nothing rather than guessing",
       /Click a claim/.test(panel.innerHTML));
  }
  ok("the folder page offers the link", /href="#\/c\/\$\{esc\(slug\)\}\/map\?ffocus=/.test(src));
  ok("the map route only accepts a folder-path shape",
     /\^\[0-9\]\+\(\\\.\[0-9\]\+\)\*\$/.test(src));

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
