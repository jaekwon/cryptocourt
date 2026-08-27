// D3 harness: cross-links + orientation. aboutTour truthfulness against DEMO,
// ?at allowlist, chip gating, map focus plumbing, crumbs orientation, §7.4.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo', chainid:'dev' };
global.isLive = ()=> CFG.mode==='live';
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = Number(NOWm[1].replace(/_/g,''));

let code = '';
code += slice('function esc(', '\n');
code += 'var NOW='+global.NOW+';\n';
// Round 28 split the literal: DEMO_CHAIN (generated) + DEMO_OVERLAY
// (hand-written: desc, nested folders, relations, voteEndsAt), joined by
// mergeDemo. Build the merged object the way the page does.
code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED').replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED').replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
// statusText names the verdict side now, so it needs sideName.
code += slice('const sideName =', '\n').replace('const sideName =','var sideName =') + '\n';
code += slice('function statusText(', '\n/* =');
code += 'function safeInline(x){ return esc(String(x)); }\n';
code += slice('function statusPill(','function docketRow(');
code += slice('function phaseClass(','function statusPill(');
code += slice('/* The specimen tour','function introStrip(');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// aboutTour: every linked id exists in DEMO and its caption matches its phase
CFG.mode='demo';
const tour = aboutTour();
const want = {1:"open",2:"answered",3:"disputed",7:"provisional",5:"provClose",4:"settled",8:"closed"};
for(const [id,phase] of Object.entries(want)){
  const d = DEMO.claims["orem/"+id];
  ok(`tour #${id} exists and is ${phase}`, d && d.phase===phase && tour.includes(`href="#/c/orem/${id}"`));
}
ok("tour titles verbatim from DEMO", tour.includes(esc(DEMO.claims["orem/4"].title)));
ok("tour labeled sample thrice", (tour.match(/sample/g)||[]).length>=3);
ok("settled row names its route", tour.includes("by vote") && tour.includes("conclusion"));
ok("disputed row keeps the tally sealed", tour.includes("not summed until the vote closes"));
ok("no finalize-ready promise on orem", !/finalize/i.test(tour));
CFG.mode='live';
const tourL = aboutTour();
ok("live: no links into the sample", !tourL.includes('href="#/c/orem') && tourL.includes("switch Source to Demo"));
CFG.mode='demo';
// §7.4 sweep of the tour copy
ok("§7.4 clean in tour", !/backing|redeem\b|profit|APR|worth|winnings|you win|wager/i.test(tour));

// source checks — chip + map link on the claim route
ok("chip reads local/sample only (cu, not chain)", src.includes('const fmClaim = cu && cu.folders && cu.folders.length? folderMeta(cu.folders,"",{}) : {};'));
// The curator-supplied label is now bounded by .tname: unbounded, a 40-char
// folder name made this anchor the widest element on the page and gave the
// whole document a horizontal scrollbar at 390px.
ok("chip label + folder path link",
   src.includes('filed under <span class="tname">${safeInline(fmClaim[id].label)}</span>'));
ok("no negative chip anywhere", !src.includes("not filed in a folder"));
ok("map link gated to the drawn window", src.includes('(!isLive() || (ccount!=null && id>ccount-50))'));
// This used to pin the inline `style="color:var(--accent-2)"` alongside the
// label. That inline colour is exactly what had to go: it beats any author
// rule, so no :hover or :focus-visible on these links could ever apply. The
// pin is the route now, not the paint.
ok("map link carries ?focus", src.includes('map?focus=${id}">on the map'));
ok("and no inline colour survives in a tagrow link",
   !/class="small" href="[^"]*" style="color:var\(--accent-2\)">(on the map|as the chain|docket|curate|map|moderation)/.test(src));

// ?at plumbing
ok("AT_OK allowlist", src.includes('const AT_OK = new Set(["resolution"])'));
ok("atTarget uses getElementById (no selector injection)", src.includes('AT_OK.has(QP.at))? document.getElementById(QP.at) : null'));
ok("hashchange prefers the at-target", src.includes('const t = atTarget();\n  if(t){ t.focus({preventScroll:true}); t.scrollIntoView(); return; }'));
ok("hashchange yields to route-landed focus", src.includes('main.contains(document.activeElement)) return;'));
ok("boot render mirrors the at-scroll", src.includes('render().then(()=>{ const t=atTarget();'));
ok("resolution anchor on both returns", (src.match(/<section id="resolution" tabindex="-1"><div class="sec-h">Resolution/g)||[]).length===2);
ok("needs title links carry ?at", src.includes('href="#/c/${esc(c.slug)}/${cl.id}?at=resolution"'));
ok("urgent box title is a link now", src.includes('${urgent.cl.id}?at=resolution"'));
ok("me pull rows carry ?at", src.includes('${esc(r.slug)}/${r.id}?at=resolution'));
ok("since-last rows do NOT (phase change lands on top)", src.includes('href="#/c/${esc(sl)}/${esc(id)}">'));

// map focus plumbing
ok("focus normalizes zero-pads, caps digits", src.includes('/^0*([1-9]\\d{0,14})$/'));
ok("malformed focus gets an honest no-echo note", src.includes("that ?focus value isn't a claim id"));
ok("404s carry a focusable heading", src.includes('<p class="page-h" style="font-size:15px'));
ok("global 404 renders crumbs", src.includes('{label:"No such page"}]) + notFound'));
ok("chip source visible in text", src.includes('cu.source==="local"? "local":"sample"}</a>'));
ok("specimen 7 counts both failed rounds", src.includes("after two failed dispute rounds"));
ok("invalid focus never reaches mountMap", src.includes('mountMap(slug, data, (mfocus!=null && validIds.has(mfocus))? mfocus : null)'));
ok("miss note tells the window size", src.includes('the map draws the newest ${parsed.length}'));
ok("demo miss note", src.includes('no claim #${mfocus} in the sample court'));
ok("ring re-applied inside put()", src.includes('if(focusId!=null){ const a=box.querySelector(`.mnode-a[data-id="${focusId}"]`); if(a) a.classList.add("focused"); }'));
ok("focused stroke distinct from hover", src.includes('.mnode-a.focused .mnode{stroke:var(--accent); stroke-width:3}'));
ok("camera lands once after initial put", src.includes('cx=n.x+n.w/2; cy=n.y+n.h/2;'));
ok("zoom from the LOD line, clamped", src.includes('z=Math.min(8, Math.max(1, 9*fit.w/(MAPK.fs.title*'));

// crumbs orientation
ok("orient line skips directory + about", src.includes('path!=="/" && !path.startsWith("/about") && store.get("cc.intro")!=="1"'));
ok("orient copy", src.includes('first time here? how this office works →'));
ok("delegated dismissal, one key", src.includes('const b = ev.target.closest("[data-introdismiss]"); if(!b) return;') && src.includes('store.set("cc.intro","1");'));
ok("directory strip button joins the delegate", src.includes('id="introdismiss" data-introdismiss'));
ok("old per-route wiring gone", !src.includes('idm.onclick'));

// PHASE AND SIDE ARE SEPARATE FIELDS, and both halves are asserted because
// folding them would be silent: mapDotClass switches on `short` with an exact
// ===, so a `short` of "settling YES" falls through to the open colour while the
// tooltip still reads correctly. The realm writes the side as sideName() —
// uppercase — and only the provisional status carries one today.
// A ROUTE CHANGE MUST ANIMATE, and all three parts are asserted because any one
// of them alone is silent: the keyframes without the call plays nothing, the call
// without the class-restart plays nothing on a repeat route, and neither shows up
// as a failure anywhere else. The reduced-motion opt-out is separate because the
// global rule above it kills transitions, not animations.
ok("render calls viewEnter at its paint point", /paintedSeq=seq; viewEnter\(\)/.test(src));
ok("viewEnter restarts the animation", /classList\.remove\("vin"\)[\s\S]{0,80}offsetWidth/.test(src));
ok("the enter animation exists", /#main\.vin\{animation:vin /.test(src));
ok("reduced motion opts out of it", /prefers-reduced-motion:reduce\)\{#main\.vin\{animation:none\}/.test(src));

/* AND IT MUST NOT BREAK THE FULL-SCREEN MAP, which is what it did. A
   position:fixed element resolves against the nearest TRANSFORMED ancestor
   instead of the viewport, so #main taking a transform collapsed .mapfull —
   pinned to inset:0 — into #main's column. Every arm above is a grep of the
   source and every one of them stayed green through it, which is the reason this
   one calls the function.
   The forwards fill is the other half: it kept the animation's transform applied
   after the run, so the collapse outlived the 140ms rather than flashing. */
ok("the enter animation does not fill forwards",
   /#main\.vin\{animation:vin [^}]*\bbackwards\}/.test(src) && !/animation:vin [^}]*\bboth\}/.test(src));
eval(slice('function viewEnter(', '\nconst routes'));
{
  const fake = hasFull => { const added=[]; return { added, offsetWidth:0,
    querySelector: sel => (sel===".mapfull" && hasFull) ? {} : null,
    classList:{ add:c=>added.push(c), remove:()=>{} } }; };
  const ordinary = fake(false); global.main = ordinary; viewEnter();
  ok("an ordinary view gets the enter animation", ordinary.added.includes("vin"));
  const full = fake(true); global.main = full; viewEnter();
  ok("a full-screen view does not, or it stops being full screen",
     !full.added.includes("vin"));
}

ok("phaseClass reads the side off a provisional status",
   phaseClass("provisional verdict NO — reopenable by a new dispute until block 900").side === "NO");
ok("phaseClass keeps short free of the side",
   phaseClass("provisional verdict NO — reopenable until block 900").short === "settling");
ok("phaseClass reports no side when the status names none",
   phaseClass("settled — every stake withdraws 1x").side === "");
ok("a settled status still classes as settled",
   phaseClass("settled — every stake withdraws 1x").short === "settled");

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
