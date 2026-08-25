// C1 harness: extract mapLayout/mapSvg from the LIVE file, render, and
// geometrically verify the generated SVG (the owner's legibility mandate).
//
// THE MAP WENT RADIAL, so the invariants moved with it. What the old set checked
// was a grid: folders were nested BOXES, claims were rows inside them, and every
// edge was routed through channel lanes and a horizontal bus so no line crossed
// anything. Three of its nine checks were about that machinery — folders
// nested-or-disjoint, claims inside folders, distinct lanes and bus tracks — and
// none of them means anything now that a folder is a node with claims hung around
// it. They are replaced by the two things the new layout actually promises:
//
//   A  every node pair — court, folder, claim alike — disjoint by ≥4u
//   B  each label inside the node that owns it
//   C  no two labels overlap
//   E  every folder and claim is REACHED by a containment spoke (connectivity,
//      which is what "claims inside folders" was really asserting)
//   F  a phase dot sits inside its claim and clear of that claim's text
//   G  a SPOKE crosses no node it does not end on. Chords are exempt BY DESIGN:
//      a direct line between two claims cannot promise that, chords are drawn
//      under the nodes for exactly that reason, and a check that demanded it
//      would re-invent the bus.
//   I  everything inside the viewBox
//
// G also needed a real segment/rect test. The old one returned `true` for any
// segment that was not axis-aligned — fine when every edge was orthogonal, and
// useless here, where it would have reported every spoke as hitting every node.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo' };
global.isLive = ()=> CFG.mode==='live';
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = Number(NOWm[1].replace(/_/g,''));

function buildCode(patch){
  let code = '';
  code += slice('function esc(', '\n');
  code += slice('function fmtN(', 'function ugnot(');
  code += 'var NOW='+global.NOW+';\n';
  code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED').replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
  code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED').replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
  code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
  code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
  code += slice('function statusText(', '\n/* =');
  code += slice('function phaseClass(', 'function docketRow');
  code += slice('const MAPK', '/* The join panel').replace('const MAPK','var MAPK');
  if(patch) code = patch(code);
  return code;
}
eval(buildCode());

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

function parseSVG(svg){
  const rects=[], texts=[], circles=[], spokes=[], chords=[];
  for(const m of svg.matchAll(/<rect class="(mnode|mfold[^"]*|mcourt)" x="([-\d.]+)" y="([-\d.]+)" width="([\d.]+)" height="([\d.]+)"(?: rx="[\d.]+")?(?: data-(?:id|fid)="(\d+)")?/g))
    rects.push({cls:m[1].split(" ")[0], x:+m[2], y:+m[3], w:+m[4], h:+m[5], ref:m[6]});
  for(const m of svg.matchAll(/<text class="mtext ?[^"]*" x="([-\d.]+)" y="([-\d.]+)" font-size="([\d.]+)" textLength="([\d.]+)"[^>]*data-owner="(\w+)">([^<]*)<\/text>/g)){
    const fs_=+m[3];
    texts.push({x:+m[1], y:+m[2]-0.8*fs_, w:+m[4], h:1.05*fs_, owner:m[5], s:m[6]});
  }
  for(const m of svg.matchAll(/<circle class="mdot ([a-z]+)" cx="([-\d.]+)" cy="([-\d.]+)" r="([\d.]+)" data-owner="(\w+)"/g))
    circles.push({cls:m[1], x:+m[2]-+m[4], y:+m[3]-+m[4], w:2*+m[4], h:2*+m[4], owner:m[5]});
  for(const m of svg.matchAll(/<polyline class="medge spoke ([a-z]+)" points="([^"]+)" data-s="(\d+)"/g))
    spokes.push({kind:m[1], pts:m[2].split(" ").map(p=>p.split(",").map(Number))});
  for(const m of svg.matchAll(/<polyline class="medge ((?!spoke)[^"]+)" points="([^"]+)" data-e="(\d+)" data-from="(\d+)" data-to="(\d+)"/g))
    chords.push({cls:m[1], pts:m[2].split(" ").map(p=>p.split(",").map(Number)), from:m[4], to:m[5]});
  const vb = svg.match(/viewBox="([-\d. ]+)"/)[1].split(" ").map(Number);
  return {rects, texts, circles, spokes, chords, vb};
}
const disjoint=(a,b,g=0)=>a.x+a.w+g<=b.x||b.x+b.w+g<=a.x||a.y+a.h+g<=b.y||b.y+b.h+g<=a.y;
const inside=(a,b)=>a.x>=b.x-0.51&&a.y>=b.y-0.51&&a.x+a.w<=b.x+b.w+0.51&&a.y+a.h<=b.y+b.h+0.51;
// Liang-Barsky: does the OPEN segment pass through the rect's interior? Shrunk by
// a hair so a spoke that merely lands on a border is not a crossing.
function segHitsRect(p,q,r,pad=1){
  const x0=r.x+pad, y0=r.y+pad, x1=r.x+r.w-pad, y1=r.y+r.h-pad;
  if(x1<=x0||y1<=y0) return false;
  let t0=0, t1=1;
  const dx=q[0]-p[0], dy=q[1]-p[1];
  for(const [num,den] of [[x0-p[0],dx],[p[0]-x1,-dx],[y0-p[1],dy],[p[1]-y1,-dy]]){
    if(den===0){ if(num>0) return false; continue; }
    const t=num/den;
    if(den<0){ if(t>t1) return false; if(t>t0) t0=t; }
    else { if(t<t0) return false; if(t<t1) t1=t; }
  }
  return t1>t0;
}
function verify(svg, label){
  const P=parseSVG(svg);
  const claims=P.rects.filter(r=>r.cls==="mnode");
  const folders=P.rects.filter(r=>r.cls==="mfold");
  const courts=P.rects.filter(r=>r.cls==="mcourt");
  const boxes=[...claims,...folders,...courts];
  const fails=[]; let minGap=Infinity;
  for(let i=0;i<boxes.length;i++) for(let j=i+1;j<boxes.length;j++){
    if(!disjoint(boxes[i],boxes[j],4)) fails.push(`A ${boxes[i].cls}${boxes[i].ref||""}/${boxes[j].cls}${boxes[j].ref||""}`);
    const gx=Math.max(boxes[j].x-(boxes[i].x+boxes[i].w), boxes[i].x-(boxes[j].x+boxes[j].w));
    const gy=Math.max(boxes[j].y-(boxes[i].y+boxes[i].h), boxes[i].y-(boxes[j].y+boxes[j].h));
    minGap=Math.min(minGap, Math.max(gx,gy));
  }
  const ownerRect=t=>t.owner[0]==="c"? claims.find(r=>r.ref===t.owner.slice(1))
    : t.owner[0]==="h"? folders[+t.owner.slice(1)] : courts[0];
  for(const t of P.texts){ const o=ownerRect(t); if(!o||!inside(t,o)) fails.push(`B ${t.owner} "${t.s}"`); }
  for(let i=0;i<P.texts.length;i++) for(let j=i+1;j<P.texts.length;j++)
    if(!disjoint(P.texts[i],P.texts[j])) fails.push(`C ${P.texts[i].owner}/${P.texts[j].owner}`);
  // E: reachability. Every folder and claim must be an endpoint of some spoke, or
  // it is drawn floating with nothing saying where it belongs.
  const ends=new Set();
  for(const s of P.spokes) for(const pt of [s.pts[0], s.pts[s.pts.length-1]])
    for(const b of boxes) if(pt[0]>=b.x-1&&pt[0]<=b.x+b.w+1&&pt[1]>=b.y-1&&pt[1]<=b.y+b.h+1) ends.add(b);
  for(const b of [...claims,...folders]) if(!ends.has(b)) fails.push(`E ${b.cls}${b.ref||""} unreached`);
  for(const d of P.circles){
    const o=claims.find(r=>r.ref===d.owner.slice(1));
    if(!o||!inside(d,o)) fails.push(`F dot ${d.owner}`);
    for(const t of P.texts) if(t.owner===d.owner && !disjoint(d,t)) fails.push(`F dot/text ${d.owner}`);
  }
  // G: spokes only. A spoke's endpoints sit on the two boxes it joins, so a box
  // it merely touches at an endpoint is not a crossing — hence the endpoint test
  // before the interior test.
  for(const s of P.spokes){
    const touches=b=>[s.pts[0],s.pts[s.pts.length-1]].some(pt=>
      pt[0]>=b.x-1&&pt[0]<=b.x+b.w+1&&pt[1]>=b.y-1&&pt[1]<=b.y+b.h+1);
    for(let k=0;k+1<s.pts.length;k++)
      for(const b of boxes) if(!touches(b)&&segHitsRect(s.pts[k],s.pts[k+1],b)) fails.push(`G spoke x ${b.cls}${b.ref||""}`);
  }
  const [bx,by,bw,bh]=P.vb;
  for(const r of [...P.rects,...P.texts,...P.circles]) if(!inside(r,{x:bx,y:by,w:bw,h:bh})) fails.push("I overflow");
  console.log(`  [${label}] claims=${claims.length} folders=${folders.length} chords=${P.chords.length} spokes=${P.spokes.length} minGap=${isFinite(minGap)?minGap.toFixed(0):"-"} vb=${bw}x${bh} -> ${fails.length?"FAIL":"PASS"}`);
  fails.slice(0,6).forEach(f=>console.log("    !!",f));
  return fails.length===0;
}

// demo orem, both modes
const c0=DEMO.courts.orem;
const claimsMap={}; c0.claims.forEach(id=>{ const d=DEMO.claims["orem/"+id]; claimsMap[id]={title:d.title, statusText:statusText(d)}; });
const demoData={folders:c0.folders, all:c0.claims, claims:claimsMap, relations:DEMO.relations.orem, linkFolders:true, courtName:"Orem Truth Court"};
let allpass=true; const svgs={};
for(const mode of ["titles","ids"]){
  const L=mapLayout(demoData,mode); const svg=mapSvg(L,demoData,"orem");
  svgs[mode]=svg;
  allpass=verify(svg,"orem/"+mode)&&allpass;
}
ok("A-I pass on demo orem (both modes)", allpass);

// live shape: 50 claims in one pseudo folder, no relations — the widest ring the
// solve has to fit, and the case where the fit rescale actually fires.
const liveClaims={}; const liveAll=[];
for(let i=1;i<=50;i++){ liveAll.push(i); liveClaims[i]={title:`Synthetic documentary claim number ${i} with a longer wrapping title.`, statusText: i%7===0?"settled — every stake withdraws 1×": i%5===0?"disputed — a sealed vote is deciding":"open — stake YES or NO"}; }
const liveData={folders:[], all:liveAll, claims:liveClaims, relations:[], looseName:"docket — newest 50", courtName:"Orem Truth Court"};
let livepass=true;
for(const mode of ["titles","ids"]){
  const L=mapLayout(liveData,mode); const svg=mapSvg(L,liveData,"orem");
  livepass=verify(svg,"live50/"+mode)&&livepass;
}
ok("A-I pass on live 50-claim ring (both modes)", livepass);

// a DEEP tree with cross-cut membership: the covid shape, which is what turned
// the org chart into a complaint. Three folder levels, six roots, one folder
// whose every claim is filed elsewhere.
{
  const T=(n,kids,claims)=>({name:n, claims:claims||[], folders:kids||[]});
  const deep=[
   T("Origins",[T("Laboratory hypothesis",[T("The 2020 question",[],[1]),T("After the agency assessments",[],[11,13])]),
                T("Natural spillover",[T("The market cluster",[],[5])])]),
   T("The document trail",[T("Grants and funding",[T("The WIV subawards",[],[2])]),
                           T("Correspondence",[T("Released under subpoena",[],[8])]),
                           T("FOIA and subpoena",[T("Withholdings",[],[10])])]),
   T("Institutions and accountability",[T("Testimony",[T("Gain-of-function funding",[],[12])]),
                                        T("NIAID and its director",[],[2,8,10,12])]),
  ];
  const dc={}; [1,2,5,8,10,11,12,13].forEach(i=>dc[i]={title:"A claim of fact stated as one sentence, number "+i+".", statusText:"open — stake YES or NO"});
  const dd={folders:deep, all:[1,2,5,8,10,11,12,13], claims:dc, courtName:"COVID-19 Origins & Response Court", linkFolders:true,
    relations:[{from:2,to:11,type:"bears",stance:"supports"},{from:5,to:11,type:"bears",stance:"contradicts"},
               {from:8,to:12,type:"bears",stance:"supports"},{from:13,to:11,type:"supersedes"}]};
  let dp=true;
  for(const mode of ["titles","ids"]){ const L=mapLayout(dd,mode); dp=verify(mapSvg(L,dd,"covid"),"covid/"+mode)&&dp; }
  ok("A-I pass on a three-level tree with a cross-cut folder", dp);
  // The cross-cut's own promise: it holds four claims that are all drawn
  // elsewhere, so it must still be joined to each of them.
  const L=mapLayout(dd,"ids");
  ok("a claim is drawn once even when two folders hold it", L.nodes.length===8);
  ok("the cross-cut folder is still joined to its four claims",
     L.spokes.filter(s=>s.kind==="also").length===4);
}

// THE WRAP, which had no owner among these checks and was broken the whole time.
// Every geometric check asks where a label SITS; none asked what it says, so a
// two-line label that kept one word and a stub on its second line — "Public
// health and / its…", "SARS-CoV-2 entered the / human…" — passed everything for
// as long as the map has existed. The property is simple: a line that has room
// for another word gets one.
{
  const fits = (lines, budget) => lines.every(l => l.length <= budget);
  const w = 136, fs_ = 12, budget = Math.floor(w/(fs_*MAPK.charW));
  const two = mapWrapTitle("Public health and its measurement", w, fs_, 2);
  ok("a two-line label fills its second line", two.length===2 && two[1]==="its measurement");
  ok("and neither line is over budget", fits(two, budget));
  ok("a title that fits exactly is not ellipsised",
     mapWrapTitle("Measures and outcomes", w, fs_, 2).join(" ")==="Measures and outcomes");
  // Still truncates when it genuinely must, and only on the LAST allowed line.
  const long = mapWrapTitle("A tribunal applying the ordinary standard would find that "
    + "congressional testimony misled the committee.", 160, 11, 2);
  ok("a title too long for the cap ends in an ellipsis", long.length===2 && /…$/.test(long[1]));
  ok("but its earlier lines are whole", !/…/.test(long[0]));
  ok("the cap is honoured", mapWrapTitle("one two three four five six seven eight nine ten",
     60, 11, 2).length===2);
  ok("a one-line cap is a single line",
     mapWrapTitle("Public health and its measurement", w, fs_, 1).length===1);
}

// CLICK SELECTS, IT DOES NOT NAVIGATE. The card is a pure function, so what it
// says can be asked directly; the interception rule is route code and is checked
// in source, which is the weaker check and labelled as such.
{
  global.safeInline = x => esc(String(x));
  eval(slice('function mapSelCard(', 'function mapDotClass'));
  const d = {claims:{7:{title:"A claim of fact, stated once, at length enough to be cut on a node.",
                        statusText:"open — stake YES or NO"}},
             relations:[{from:7,to:9,type:"bears",stance:"supports"},
                        {from:7,to:8,type:"bears",stance:"contradicts"},
                        {from:5,to:7,type:"bears",stance:"contradicts"},
                        {from:6,to:7,type:"supersedes"}]};
  const html = mapSelCard(7, d, "covid");
  ok("the card names the claim", html.includes("#7"));
  // The node shows two wrapped lines and an ellipsis; the card is the one place
  // the sentence appears whole without leaving the map.
  ok("and shows the title UNTRUNCATED",
     html.includes("A claim of fact, stated once, at length enough to be cut on a node."));
  ok("it tallies what the claim asserts", /asserts:[^<]*1 supports/.test(html) && /asserts:[^<]*1 contradicts/.test(html));
  ok("and what is asserted about it", /asserted about it:[^<]*1 contradicts/.test(html)
     && /asserted about it:[^<]*1 supersedes/.test(html));
  ok("the claim page is offered, not taken", html.includes('href="#/c/covid/7"')
     && html.includes("Open claim page"));
  ok("and the selection can be cleared", html.includes('id="msel-x"'));
  ok("a claim with no relations says so",
     mapSelCard(7, {claims:d.claims, relations:[]}, "covid").includes("no relations drawn"));
  ok("an unknown id renders nothing", mapSelCard(99, d, "covid")==="");

  // Source-level, because these live in the route's listeners.
  const mount = slice('function mountMap(', '/* Folder page');
  ok("a plain click on a claim is intercepted",
     /ev\.preventDefault\(\);\s*select\(\{kind:"claim"/.test(mount));
  ok("and a plain click on a FOLDER is too",
     /ev\.preventDefault\(\);\s*select\(\{kind:"folder"/.test(mount));
  // An <a> that stops behaving like one is worse than a button: modified clicks
  // and middle-click must still open the claim in a tab.
  ok("modified and middle clicks still follow the link",
     /ev\.metaKey\|\|ev\.ctrlKey\|\|ev\.shiftKey\|\|ev\.altKey\|\|ev\.button!==0/.test(mount));
  ok("a drag that ends on a node does not select it", /if\(dragged\)/.test(mount));
  ok("hover does not fight a held selection",
     ["mouseover","mouseout","focusin"].every(evt =>
        new RegExp(`addEventListener\\("${evt}"[^\\n]*if\\(sel\\) return;`).test(mount)));
  ok("escape clears the selection", /ev\.key==="Escape"/.test(mount));

  // ---- the folder card ----
  eval(slice('function mapFolderCard(', 'function mapDotClass'));
  const fd = {claims:{1:{title:"A claim about the record, long enough that the card has to cut it somewhere sensible."},
                      2:{title:"Another"}}, linkFolders:true};
  const fc = mapFolderCard({name:"Fauci", count:9, subs:3, claims:[1,2], path:"2"}, fd, "covid");
  ok("the folder card names the folder", fc.includes("Fauci"));
  ok("it counts the whole subtree and the subfolders", fc.includes("9 claims in all")
     && fc.includes("3 subfolders") && fc.includes("2 filed here directly"));
  ok("it lists the claims filed directly in it", fc.includes('data-go="1"') && fc.includes('data-go="2"'));
  ok("and offers the folder page rather than taking it",
     fc.includes('href="#/c/covid/f/2"') && fc.includes("Open folder page"));
  // The loose bucket is the map's own, not a folder the court filed — a link
  // there would 404 on a path that does not exist.
  const pf = mapFolderCard({name:"docket — newest 50", count:50, subs:0, claims:[1], pseudo:true, path:null}, fd, "covid");
  ok("a pseudo folder offers no page and says why",
     !pf.includes("Open folder page") && pf.includes("the map's own bucket"));
  // Fifty claims is a docket page, not a card.
  const many = mapFolderCard({name:"big", count:40, subs:0, claims:[...Array(40).keys()].map(i=>i+1), path:"1"},
                             {claims:Object.fromEntries([...Array(40).keys()].map(i=>[i+1,{title:"t"}])), linkFolders:true}, "covid");
  ok("a long claim list is capped, and says how many it dropped",
     (many.match(/data-go=/g)||[]).length===12 && many.includes("and 28 more"));
  ok("clicking a listed claim selects it rather than navigating",
     /\.mapsel-c[\s\S]{0,200}select\(\{kind:"claim"/.test(mount));
  ok("a selected folder dims to its own subtree", /function dimFolder/.test(mount));

  /* THE CARD MUST NOT COVER THE MAP. It did: absolutely positioned at top-right
     with a z-index, which made every node under it unclickable — clicking a claim
     in that corner while a card was open did nothing at all, and the card sat
     there looking as though it had ignored the input. It had not; the click never
     reached the SVG. This is a CSS property and so is asked of the stylesheet,
     which is the weakest check here and the reason the bug survived review. */
  const css = slice('.maphold{', '@media (max-width:860px)');
  ok("the card has its own column rather than floating over the map",
     /\.maphold\{[^}]*grid-template-columns/.test(css) && !/\.mapsel\{[^}]*position:absolute/.test(css));
  ok("and the column is reserved, so selecting cannot resize the map",
     !/\.mapsel\[hidden\]|display:none/.test(css));
  ok("the empty column explains that the map is interactive",
     /mapsel-hint/.test(mount) && /Click a claim/.test(mount));
  ok("and it is painted at mount, not only after the first click",
     /put\(\);\s*paint\(\);/.test(mount));
}

// NODES SIZED TO THEIR OWN TEXT, and rings compacted radially.
{
  const short = "Short.", long = "A tribunal applying the ordinary standard would find that "
    + "congressional testimony misled the committee about what was funded and when.";
  const d = {folders:[{name:"F", claims:[1,2], folders:[], path:"0"}], all:[1,2],
             claims:{1:{title:short, statusText:"open"}, 2:{title:long, statusText:"open"}},
             relations:[], courtName:"C", linkFolders:true};
  const L = mapLayout(d, "titles");
  const h = Object.fromEntries(L.nodes.map(n=>[n.id, n.h]));
  ok("a short claim gets a short box", h[1] < h[2]);
  ok("and a long one grows to hold more of its sentence", h[2] >= h[1] + MAPK.lineH);
  ok("no box is shorter than the floor", Math.min(h[1], h[2]) >= MAPK.node.titles.h);
  ok("ids mode keeps one fixed size", (()=>{ const I=mapLayout(d,"ids");
     return new Set(I.nodes.map(n=>n.h)).size===1; })());

  /* RING 1 SITS AT ITS OWN MINIMUM, not at whatever the outermost ring's
     overflow scaled it to. The uniform fit put the covid docket's rings at
     0/303/619/977 when ring 1's contents needed 193 — a hole in the middle of
     the drawing exactly where the reader looks. Compaction moves rings only;
     angles are untouched, which is why nothing it does can invalidate a wedge. */
  const deep = {folders:[{name:"A", claims:[], folders:[{name:"A1", claims:[1,2,3,4,5,6,7], folders:[]}], path:"0"},
                         {name:"B", claims:[], folders:[{name:"B1", claims:[8,9], folders:[]}], path:"1"}],
                all:[1,2,3,4,5,6,7,8,9],
                claims:Object.fromEntries([1,2,3,4,5,6,7,8,9].map(i=>[i,{title:long, statusText:"open"}])),
                relations:[], courtName:"C", linkFolders:true};
  const D2 = mapLayout(deep, "titles");
  const court = MAPK.cnode.titles, fold = MAPK.fnode.titles;
  ok("ring 1 clears the court and no more",
     D2.rings[1] <= Math.max(court.w, court.h)/2 + Math.max(fold.w, fold.h)/2 + MAPK.sep + 2);
  ok("rings still increase outward", D2.rings.every((r,i)=> i===0 || r > D2.rings[i-1]));

  /* A SPARSE SUBTREE IS NOT EXILED BY A CROWDED ONE THAT SHARES ITS DEPTH.
     Radius is a property of a sibling group, not of a depth: under one radius per
     ring, a ring can only be as tight as its worst wedge, so two claims got flung
     out to wherever twenty needed to be. On the real covid docket that cost
     392px — "The iPhone texts" sat at r=1040 with three claims because
     "Gain-of-function funding" happened to share its depth.
     Groups may move independently because angular sectors are DISJOINT: two
     boxes in non-overlapping sectors cannot touch at any pair of radii, and the
     only pair that can collide is a parent and its own descendant, which the
     clearance term bounds from the parent's real radius.
     THE FIXTURE IS ITS OWN, AND IT HAS TO BE NESTED AND LOPSIDED. `deep` was
     used first and quietly stopped discriminating when the claim box was
     re-proportioned: with taller boxes the CLEARANCE term dominates both groups
     and they land within 4px of each other, so the assertion passed on both the
     right and the wrong layout. Measured over candidate shapes, and worth
     recording because it says where this effect lives:

       A=7  B=2 nested   per-group 592/592     no separation at all
       A=14 B=2 nested   per-group 655/643     12px, still not a guard
       A=20 B=1 nested   per-group 900/600     300px  <-- this one
       A=14 B=2 flat     per-group 581/581     no separation
       A=20 B=2 flat     per-group 792/792     no separation

     FLAT DOCKETS NEVER SEPARATE, which is not a defect in the fixture but the
     shape of the thing: a folder's angular share is already proportional to how
     many leaves it carries, so at one level down every group needs the same
     radius and per-depth is accidentally correct. The win only exists BELOW a
     subfolder, where a group inherits an angular share sized for its parent's
     whole subtree — which is exactly where the covid docket lost its 392px.
     ONE ASSERTION, AND TWO MORE I WROTE AND THREW AWAY. The others were "a
     sibling group sits on one arc" and "a claim sits outside its folder". Both
     are true and neither could be armed: breaking the code they describe — per
     node wedge bounds for the first, clearance measured from the ring instead of
     from the parent for the second — left them green, because the overlap and
     containment invariants above already fail on those mutations. An assertion no
     mutation can turn red guards nothing; it just reads as though it does. */
  {
    const sub = (name, ids) => ({name, claims:[], path:name,
                                 folders:[{name:name+"1", claims:ids, folders:[]}]});
    const many = [...Array(20).keys()].map(i => i+1), one = [21];
    const lop = {folders:[sub("A", many), sub("B", one)], all:[...many, ...one],
                 claims:Object.fromEntries([...many, ...one].map(i => [i,
                   {title:long, statusText:"open"}])),
                 relations:[], courtName:"C", linkFolders:true};
    const P = mapLayout(lop, "titles");
    const r = id => { const n = P.nodes.find(x => x.id === id);
                      return Math.hypot(n.cx - P.court.cx, n.cy - P.court.cy); };
    // Against the crowded group's OUTER arc. It used to read `Math.min(...)`,
    // which was the same number until the twenty-claim group learned to sit on
    // two arcs and its inner one came in past the lone claim. What the check is
    // about is that ONE claim is not sent out to where TWENTY have to be.
    ok("a one-claim group comes in close, not out to where twenty claims need to be",
       r(21) < Math.max(...many.map(r)) - 100);

    /* AND THE TWENTY SIT ON TWO ARCS. Interleaving by position lets every other
       claim spill into its neighbours' wedges, because the only boxes it can now
       reach are on the other arc, radially separated by their own extents plus
       the clearance. The arc that remains is bounded by what TWO wedges hold
       rather than one, which is half the radius. The outer arc does not move —
       it is pinned by the group's end claims, which have a neighbouring subtree
       past them and get the plain one-arc bound — so this does not shrink the
       drawing. It fills it: measured on a 28-claim flat docket, half the claims
       moved from 928 to 518 with the graph the same size. */
    const arcs = [...new Set(many.map(id => Math.round(r(id))))].sort((a,b) => a-b);
    ok("a crowded group splits onto two arcs rather than one distant ring",
       arcs.length === 2);
    ok("...and the inner arc is materially closer, not a hair's separation",
       arcs.length === 2 && arcs[0] < arcs[1] * 0.8);
  }

  /* "(no folder)" IS A CONTRAST, AND A COURT WITH NO FOLDERS HAS NOTHING TO
     CONTRAST WITH. Every loose claim used to be wrapped in a pseudo folder
     unconditionally, so a court nobody had curated — a new one, which is every
     court at some point — drew its whole docket inside a box labelled "(no
     folder)". That box contained everything, said nothing, and cost a ring: the
     claims became depth 2 and were pushed outside a container whose only content
     was the word "no". Two claims sat 342 from the court where 258 is the
     clearance; measured across sizes it is -84 on every docket small enough for
     the clearance to bind, and 15-20% off the drawing.
     BOTH DIRECTIONS ARE PINNED HERE, because the fix is easy to over-apply. The
     node earns its place the moment ONE claim is filed somewhere, since then
     "outside every folder" is a real thing to be. */
  {
    const T = t => ({title:t, statusText:"open"});
    const bare = {folders:[], all:[1,2], claims:{1:T("One."), 2:T("Two.")},
                  relations:[], courtName:"C", linkFolders:true};
    const B = mapLayout(bare, "titles");
    ok("a court with no folders draws no folder", B.folders.length === 0);
    ok("...and hangs its claims straight off the court",
       B.nodes.length === 2 && B.nodes.every(n => n.depth === 1));

    const mixed = {folders:[{name:"F", claims:[1], folders:[], path:"0"}], all:[1,2],
                   claims:{1:T("Filed."), 2:T("Loose.")},
                   relations:[], courtName:"C", linkFolders:true};
    const M = mapLayout(mixed, "titles");
    ok("but a court with one folder still names what sits outside it",
       M.folders.some(f => f.pseudo));
    ok("...and puts the loose claim inside that, not on the court",
       (M.nodes.find(n => n.id === 2) || {}).depth === 2);
  }

  /* A FOLDER IS AS WIDE AS ITS OWN LABEL — the other half of "nodes are not
     sized to their text", which claims got and folders did not. Every folder was
     164 wide whether it read "Fauci · 9" or "Gain-of-function funding · 3", and
     a folder's width is charged to its whole ring.
     THE FIT TEST ITSELF WAS WRONG, and this is the assertion that matters most
     here. `wrapFit` decided whether a label survived its box by asking whether
     the wrapped lines were still as long as the label — and mapWrapTitle appends
     an ellipsis when it truncates, which puts back almost exactly the length it
     removed. "Gain-of-functio funding · 3…" and "Gain-of-function funding · 3"
     are both 28 characters, so a cut label tested as a whole one. It never fired
     while every folder was a fixed 164 and every label happened to fit; allowing
     narrower boxes surfaced it immediately, which is the usual way a constant
     stops covering the case it was chosen for. */
  {
    const fold = (name, id) => ({name, claims:[id], folders:[], path:name});
    const wide = "Gain-of-function funding", thin = "Fauci";
    const d3 = {folders:[fold(thin,1), fold(wide,2)], all:[1,2],
                claims:{1:{title:"A.",statusText:"open"}, 2:{title:"B.",statusText:"open"}},
                relations:[], courtName:"C", linkFolders:true};
    const F = mapLayout(d3, "titles");
    const box = nm => F.folders.find(f => f.name === nm);
    ok("a short-named folder gets a narrower box than a long-named one",
       box(thin).w < box(wide).w);
    ok("and neither is the old fixed width for both",
       box(thin).w !== box(wide).w);

    /* The OBSERVABLE, stated here rather than borrowed from the page. The first
       version of this called mapWrapHolds — the function the bug was in — so
       breaking it left the check green: the test asked the suspect whether the
       suspect was lying. What is actually being asserted is that the drawn label
       contains no ellipsis and is no shorter than the label it stands for, which
       is a fact about the picture and belongs in the test in those terms. */
    const survives = f => {
      const label = `${f.name} · ${f.count}`;
      const lines = mapWrapTitle(label, f.w - 2*MAPK.tpad, MAPK.fs.header,
                                 Math.max(1, Math.floor((f.h-6)/(MAPK.fs.header+2))));
      const drawn = lines.join(" ");
      const orphan = lines.length > 1 && !/[A-Za-z]/.test(lines[lines.length-1]);
      return drawn.indexOf("…") < 0 && drawn.length >= label.length && !orphan;
    };
    ok("every folder box holds its whole label, count included",
       F.folders.every(survives));
    ok("...including the long one, which is the case the box was widened for",
       survives(box(wide)));
    ok("and the court is still the widest node, whatever a folder is called",
       F.folders.every(f => f.w < F.court.w));
  }

  /* AN ELLIPSIS IS A PROMISE THAT THERE IS MORE OF THE TEXT, and on an id there
     is not. The zoomed-out map asked each claim box for "#8 · settled" in a
     64-wide box less 14 for the dot and 16 for padding — about six characters —
     so every claim on it read "#8 …". The phase those four characters stood for
     is on the node already, as the colour of the dot the legend explains, and in
     full in the tooltip. In ids mode the id is the whole label. */
  {
    const d4 = {folders:[{name:"F", claims:[1,2], folders:[], path:"0"}], all:[1,2],
                claims:{1:{title:"A claim.", statusText:"settled — every stake withdraws"},
                        2:{title:"Another.", statusText:"open — stake YES or NO"}},
                relations:[], courtName:"C", linkFolders:true};
    const heads = mode => {
      const svg = mapSvg(mapLayout(d4, mode), d4, "s");
      // the claim's HEADER label: owned by the claim, and not the title line
      return [...svg.matchAll(/<text class="mtext "[^>]*data-owner="c(\d+)"[^>]*>([^<]*)</g)]
        .map(m => m[2]);
    };
    const ids = heads("ids");
    ok("ids mode labels a claim with its id and nothing else",
       ids.length === 2 && ids.every(t => /^#\d+$/.test(t.trim())));
    ok("...so no claim on the zoomed-out map promises text it does not show",
       ids.every(t => t.indexOf("…") < 0));
    ok("but titles mode still says the phase, where there is room for it",
       heads("titles").every(t => /settled|open/.test(t)));

    /* AND THE COURT KEEPS ITS OWN NAME. The zoomed-out map called a 32-character
       court "COVID-19 Origins &..." — the one node the whole drawing hangs off,
       cut off, in the view you use to see the whole drawing. It grows downward
       to fit, and that is FREE: the court is at the origin, so what ring 1 must
       clear is max(w, h), and while the height stays under the width nothing
       moves. Both fixtures' ids viewBoxes are unchanged to the pixel. */
    const longName = {folders:[], all:[1], claims:{1:{title:"A.", statusText:"open"}},
                      relations:[], courtName:"COVID-19 Origins & Response Court",
                      linkFolders:true};
    for(const m of ["ids","titles"]){
      const L4 = mapLayout(longName, m), c = L4.court;
      const cap = Math.max(1, Math.floor((c.h-6)/(MAPK.fs.court+2)));
      const drawn = mapWrapTitle(c.name, c.w - 2*MAPK.tpad, MAPK.fs.court, cap).join(" ");
      ok(`the court's whole name fits its box (${m})`,
         drawn.indexOf("…") < 0 && drawn.length >= c.name.length);
      ok(`...and it grew downward only, so ring 1 did not pay for it (${m})`,
         c.h <= c.w);
    }

    /* A FOLDER SAYS ITS WHOLE NAME ON HOVER. Every claim already did and no
       folder did. A box can be sized to its label — folders are, now — but a
       label can outrun any box: names run to 200 characters on chain, and in ids
       mode the box is 112 wide whatever the name. So the zoomed-out map showed
       "Vaccine…", "Proximal…", "Gain-of-fun…" and offered no way to resolve them
       short of changing mode. The tooltip costs the layout nothing. */
    const d5 = {folders:[{name:"Gain-of-function funding", claims:[1], folders:[], path:"0"}],
                all:[1], claims:{1:{title:"A.", statusText:"open"}},
                relations:[], courtName:"C", linkFolders:true};
    for(const m of ["ids","titles"])
      ok(`a folder carries its whole name and count in a tooltip (${m})`,
         mapSvg(mapLayout(d5, m), d5, "s")
           .includes("<title>Gain-of-function funding · 1</title>"));
    const drawn = [...mapSvg(mapLayout(d5, "ids"), d5, "s")
      .matchAll(/class="mtext mhdr-t"[^>]*>([^<]*)</g)].map(x => x[1]).join(" ");
    ok("...and it is doing work: at that size the drawn label is cut",
       drawn.indexOf("…") >= 0);
  }

  /* THE COURT IS THE WIDEST NODE, and this asked for AREA until the claim box
     was widened to hold more of a title. That was the wrong property and it is
     worth saying why rather than just relaxing it: area conflates two things,
     and it made the court's size a function of the longest title on the docket —
     grow a claim to four lines and the court had to grow to out-area it, which
     is backwards. What makes the court read as the anchor is that it is the
     widest node, the only filled one, and at the centre. A claim that got tall
     to hold its sentence is not competing for that; it is out in a ring. */
  for(const m of ["titles","ids"]){
    const M = mapLayout(deep, m);
    ok(`the court is the widest node (${m})`,
       M.nodes.concat(M.folders).every(b => b.w < M.court.w));
    ok(`and outweighs every folder (${m})`,
       M.folders.every(b => b.w*b.h < M.court.w*M.court.h));
  }
}

// determinism: same input → same bytes
ok("deterministic bytes", mapSvg(mapLayout(demoData,"titles"),demoData,"orem")===svgs.titles);

// the court is the centre, and it is one node
ok("exactly one court node, and it is not a link",
   (svgs.titles.match(/class="mcourt"/g)||[]).length===1 && !/<a[^>]*>\s*<rect class="mcourt"/.test(svgs.titles));
{
  const L=mapLayout(demoData,"titles");
  const cx=L.court.cx, cy=L.court.cy;
  const far=L.nodes.concat(L.folders).map(b=>Math.hypot(b.cx-cx,b.cy-cy));
  ok("every folder and claim sits outside the court", Math.min(...far) > L.court.w/2);
  // claims hang off folders, so they are the outer ring
  const fr=L.folders.map(b=>Math.hypot(b.cx-cx,b.cy-cy));
  const nr=L.nodes.map(b=>Math.hypot(b.cx-cx,b.cy-cy));
  ok("claims sit further out than the shallowest folders", Math.max(...nr) > Math.max(...fr)*0.9);
}

// NEGATIVE control: collapse the clearance → the harness must FAIL
{
  const badNS={};
  const badCode = buildCode(c=>c.replace("sep:22,","sep:-90,"));
  const f=new Function("g", badCode + "; g.mapLayout=mapLayout; g.mapSvg=mapSvg;");
  f(badNS);
  const Lb=badNS.mapLayout(demoData,"titles"); const svgB=badNS.mapSvg(Lb,demoData,"orem");
  const silent=[]; const orig=console.log; console.log=(...a)=>silent.push(a.join(" "));
  const badPass=verify(svgB,"negative");
  console.log=orig;
  ok("negative control detected (collapsed clearance fails)", badPass===false);
}

// §7.4 sweep of the generated map output
ok("no amounts/banned words in map output", !/CC\b|µGNOT|GNOT|%|stake|backing|redeem|profit/i.test(svgs.titles.replace(/aria-label="[^"]*"/,'').replace(/<title>[\s\S]*?<\/title>/g,'')));
// dot classes agree with statusPill families for every orem claim
{
  let agree=true;
  for(const id of c0.claims){
    const pc=phaseClass(claimsMap[id].statusText);
    const m=svgs.titles.match(new RegExp(`<circle class="mdot ([a-z]+)"[^>]*data-owner="c${id}"`));
    const dot=m&&m[1];
    const wantFamily={settled:"g","in dispute":"e",settling:"ed",answered:"o","no decision":"vd","never answered":"vf",open:"v"}[pc.short];
    if(dot!==wantFamily) { agree=false; console.log("  dot mismatch #"+id, dot, "want", wantFamily); }
  }
  ok("dot classes agree with phaseClass on all 11 claims", agree);
}
ok("nodes are links", (svgs.titles.match(/<a href="#\/c\/orem\/\d+"/g)||[]).length===11);
ok("folder nodes link to folder pages", svgs.titles.includes('href="#/c/orem/f/0"'));
ok("count line present in source", src.includes("${data.all.length} claims, ${data.all.length} shown"));
ok("live honesty lines present (chain-read + no-folders)", src.includes("folders read from the chain — moderator curation") && src.includes("this court's moderators have filed no folders"));
ok("controls present", ["mt-titles","mt-ids","mz-in","mz-out","mz-fit","mz-slider"].every(id=>src.includes(id)));
/* FULL SCREEN NEEDS A WAY OUT, and more than one: a fixed overlay with no visible
   exit is a trap, and Escape does not count because nothing advertises it. Two
   links back to the court — the named one on the left, the close on the right —
   plus curate, which was page furniture on the old map page and got dropped when
   the furniture moved into the bar. curation_test.js caught that one. */
{
  const route = slice("/* THE MAP TAKES THE WHOLE SCREEN.", "  mountMap(slug, data,");
  ok("the map route is a fixed full-screen layer", /class="mapfull"/.test(route));
  ok("and the first thing in its bar is the way back",
     route.indexOf("mapback") < route.indexOf("mapbar-t"));
  ok("with a second exit at the other end", /mapbar-x/.test(route)
     && (route.match(/href="#\/c\/\$\{esc\(slug\)\}"/g)||[]).length >= 2);
  ok("curate stays reachable from the map", /\/curate">curate/.test(route));
  ok("the map fills what is left, with no fixed height",
     /\.maphold\{[^}]*flex:1/.test(src) && !/\.mapwrap svg\{[^}]*height:clamp/.test(src));
}

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
