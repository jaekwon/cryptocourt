// C1 harness: extract mapLayout/mapSvg from the LIVE file, render, and
// geometrically verify the generated SVG (the owner's legibility mandate):
// A node pairs disjoint (≥4u), B text-in-owner, C text pairs disjoint,
// D folders nested-or-disjoint, E claims inside folders, F dots clear,
// G edges cross no non-endpoint node and no header, H distinct lanes/tracks,
// I everything in the viewBox — per text mode, demo + live shapes, plus a
// NEGATIVE control and a §7.4 string sweep.
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
  // Round 28 split the literal: DEMO_CHAIN (generated) + DEMO_OVERLAY
// (hand-written: desc, nested folders, relations, voteEndsAt), joined by
// mergeDemo. Build the merged object the way the page does.
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
const estW=(t,fs_)=>t.length*fs_*0.62;

function parseSVG(svg){
  const rects=[], texts=[], circles=[], polys=[];
  for(const m of svg.matchAll(/<rect class="(mnode|mfold[^"]*|mhdr)" x="([-\d.]+)" y="([-\d.]+)" width="([\d.]+)" height="([\d.]+)"(?: data-(?:id|fid)="(\d+)")?/g))
    rects.push({cls:m[1].split(" ")[0], x:+m[2], y:+m[3], w:+m[4], h:+m[5], ref:m[6]});
  for(const m of svg.matchAll(/<text class="mtext[^"]*" x="([-\d.]+)" y="([-\d.]+)" font-size="([\d.]+)" textLength="([\d.]+)"[^>]*data-owner="(\w+)">([^<]*)<\/text>/g)){
    const fs_=+m[3];
    texts.push({x:+m[1], y:+m[2]-0.8*fs_, w:+m[4], h:1.05*fs_, owner:m[5], s:m[6]});
  }
  for(const m of svg.matchAll(/<circle class="mdot ([a-z]+)" cx="([-\d.]+)" cy="([-\d.]+)" r="([\d.]+)" data-owner="(\w+)"/g))
    circles.push({cls:m[1], x:+m[2]-+m[4], y:+m[3]-+m[4], w:2*+m[4], h:2*+m[4], owner:m[5]});
  for(const m of svg.matchAll(/<polyline class="medge ([^"]+)" points="([^"]+)" data-e="(\d+)" data-from="(\d+)" data-to="(\d+)"/g))
    polys.push({cls:m[1], pts:m[2].split(" ").map(p=>p.split(",").map(Number)), from:m[4], to:m[5]});
  const vb = svg.match(/viewBox="([-\d. ]+)"/)[1].split(" ").map(Number);
  return {rects, texts, circles, polys, vb};
}
const disjoint=(a,b,g=0)=>a.x+a.w+g<=b.x||b.x+b.w+g<=a.x||a.y+a.h+g<=b.y||b.y+b.h+g<=a.y;
const inside=(a,b)=>a.x>=b.x&&a.y>=b.y&&a.x+a.w<=b.x+b.w&&a.y+a.h<=b.y+b.h;
function segHitsRect(p,q,r){
  const [x1,y1]=p,[x2,y2]=q;
  if(y1===y2) return y1>r.y&&y1<r.y+r.h&&Math.max(x1,x2)>r.x&&Math.min(x1,x2)<r.x+r.w;
  if(x1===x2) return x1>r.x&&x1<r.x+r.w&&Math.max(y1,y2)>r.y&&Math.min(y1,y2)<r.y+r.h;
  return true;
}
function verify(svg, label){
  const P=parseSVG(svg);
  const claims=P.rects.filter(r=>r.cls==="mnode");
  const folders=P.rects.filter(r=>r.cls==="mfold");
  const hdrs=P.rects.filter(r=>r.cls==="mhdr");
  const fails=[]; let minGap=Infinity;
  for(let i=0;i<claims.length;i++) for(let j=i+1;j<claims.length;j++){
    if(!disjoint(claims[i],claims[j],4)) fails.push(`A #${claims[i].ref}/#${claims[j].ref}`);
    const gx=Math.max(claims[j].x-(claims[i].x+claims[i].w), claims[i].x-(claims[j].x+claims[j].w));
    const gy=Math.max(claims[j].y-(claims[i].y+claims[i].h), claims[i].y-(claims[j].y+claims[j].h));
    minGap=Math.min(minGap, Math.max(gx,gy));
  }
  const ownerRect=t=>t.owner[0]==="c"? claims.find(r=>r.ref===t.owner.slice(1)) : hdrs[+t.owner.slice(1)];
  for(const t of P.texts){ const o=ownerRect(t); if(!o||!inside(t,o)) fails.push(`B ${t.owner} "${t.s}"`); }
  for(let i=0;i<P.texts.length;i++) for(let j=i+1;j<P.texts.length;j++)
    if(!disjoint(P.texts[i],P.texts[j])) fails.push(`C ${P.texts[i].owner}/${P.texts[j].owner}`);
  for(let i=0;i<folders.length;i++) for(let j=i+1;j<folders.length;j++){
    const a=folders[i],b=folders[j];
    if(!disjoint(a,b)&&!inside(a,b)&&!inside(b,a)) fails.push(`D ${a.ref}/${b.ref}`);
  }
  for(const c of claims) if(!folders.some(f=>inside(c,f))) fails.push(`E #${c.ref}`);
  for(const d of P.circles){
    const o=claims.find(r=>r.ref===d.owner.slice(1));
    if(!o||!inside(d,o)) fails.push(`F dot ${d.owner}`);
    for(const t of P.texts) if(t.owner===d.owner && !disjoint(d,t)) fails.push(`F dot/text ${d.owner}`);
  }
  for(const e of P.polys){
    const skip=new Set([e.from,e.to]);
    for(let s2=0;s2+1<e.pts.length;s2++){
      for(const c of claims) if(!skip.has(c.ref)&&segHitsRect(e.pts[s2],e.pts[s2+1],c)) fails.push(`G e${e.from}->${e.to} x #${c.ref}`);
      for(const h of hdrs) if(segHitsRect(e.pts[s2],e.pts[s2+1],h)) fails.push(`G e${e.from}->${e.to} x hdr`);
    }
  }
  const busYs=P.polys.filter(p=>p.pts.length===6).map(p=>p.pts[2][1]);
  if(new Set(busYs).size!==busYs.length) fails.push("H bus");
  const vxs=P.polys.flatMap(p=>p.pts.length===6? [p.pts[1][0],p.pts[3][0]] : [p.pts[1][0]]);
  if(new Set(vxs).size!==vxs.length) fails.push("H lane");
  const [bx,by,bw,bh]=P.vb;
  for(const r of [...P.rects,...P.texts,...P.circles]) if(!inside(r,{x:bx,y:by,w:bw,h:bh})) fails.push("I overflow");
  console.log(`  [${label}] nodes=${claims.length} folders=${folders.length} edges=${P.polys.length} minGap=${isFinite(minGap)?minGap.toFixed(0):"-"} vb=${bw}x${bh} -> ${fails.length?"FAIL":"PASS"}`);
  fails.slice(0,6).forEach(f=>console.log("    !!",f));
  return fails.length===0;
}

// demo orem, both modes
const c0=DEMO.courts.orem;
const claimsMap={}; c0.claims.forEach(id=>{ const d=DEMO.claims["orem/"+id]; claimsMap[id]={title:d.title, statusText:statusText(d)}; });
const demoData={folders:c0.folders, all:c0.claims, claims:claimsMap, relations:DEMO.relations.orem, linkFolders:true};
let allpass=true; const svgs={};
for(const mode of ["titles","ids"]){
  const L=mapLayout(demoData,mode); const svg=mapSvg(L,demoData,"orem");
  svgs[mode]=svg;
  allpass=verify(svg,"orem/"+mode)&&allpass;
}
ok("A-I pass on demo orem (both modes)", allpass);

// live shape: 50 claims, one pseudo box, no relations (multi-column wrap)
const liveClaims={}; const liveAll=[];
for(let i=1;i<=50;i++){ liveAll.push(i); liveClaims[i]={title:`Synthetic documentary claim number ${i} with a longer wrapping title.`, statusText: i%7===0?"settled — every stake withdraws 1×": i%5===0?"disputed — a sealed vote is deciding":"open — stake YES or NO"}; }
const liveData={folders:[], all:liveAll, claims:liveClaims, relations:[], looseName:"docket — newest 50"};
let livepass=true;
for(const mode of ["titles","ids"]){
  const L=mapLayout(liveData,mode); const svg=mapSvg(L,liveData,"orem");
  livepass=verify(svg,"live50/"+mode)&&livepass;
}
ok("A-I pass on live 50-claim box (both modes)", livepass);

// determinism: same input → same bytes
ok("deterministic bytes", mapSvg(mapLayout(demoData,"titles"),demoData,"orem")===svgs.titles);

// NEGATIVE control: corrupt vgap → harness must FAIL
{
  const badNS={};
  const badCode = buildCode(c=>c.replace("vgap:12,","vgap:-20,"));
  const f=new Function("g", badCode + "; g.mapLayout=mapLayout; g.mapSvg=mapSvg;");
  f(badNS);
  const Lb=badNS.mapLayout(demoData,"titles"); const svgB=badNS.mapSvg(Lb,demoData,"orem");
  const silent=[]; const orig=console.log; console.log=(...a)=>silent.push(a.join(" "));
  const badPass=verify(svgB,"negative");
  console.log=orig;
  ok("negative control detected (corrupt vgap fails)", badPass===false);
}

// §7.4 sweep of the generated map output
ok("no amounts/banned words in map output", !/CC\b|µGNOT|GNOT|%|stake|backing|redeem|profit/i.test(svgs.titles.replace(/aria-label="[^"]*"/,'')));
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
// every node is a link; folder headers link (demo)
ok("nodes are links", (svgs.titles.match(/<a href="#\/c\/orem\/\d+"/g)||[]).length===11);
ok("folder headers link to folder pages", svgs.titles.includes('href="#/c/orem/f/0"'));
// map chrome strings exist in the source (route-level, not extractable)
ok("count line present in source", src.includes("${data.all.length} claims, ${data.all.length} shown"));
ok("live honesty lines present (chain-read + no-folders)", src.includes("folders read from the chain — moderator curation") && src.includes("this court's moderators have filed no folders"));
ok("controls present", ["mt-titles","mt-ids","mz-in","mz-out","mz-fit","mz-slider"].every(id=>src.includes(id)));

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
