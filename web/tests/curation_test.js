// C2 harness: cleanCuration acceptance/rejection per rule, curationFor
// precedence, export→import idempotence, label strings, §7.4 sweep.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice } = require("./srcslice");
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo', chainid:'dev' };
global.isLive = ()=> CFG.mode==='live';
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = Number(NOWm[1].replace(/_/g,''));

const mem = {};
global.localStorage = { getItem:k=>mem[k]??null, setItem:(k,v)=>{mem[k]=v;}, removeItem:k=>{delete mem[k];} };

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
code += "var store={get:k=>{try{return localStorage.getItem(k)}catch(_){return null}},set:(k,v)=>{try{localStorage.setItem(k,v)}catch(_){}},del:k=>{try{localStorage.removeItem(k)}catch(_){}}};\n";
code += "const demoCourt = slug => Object.hasOwn(DEMO.courts, slug)? DEMO.courts[slug] : null;\n";
code += slice('const CURATION_V', '/* ======').replace('const CURATION_V','var CURATION_V');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };
const base = ()=>({kourtCuration:1, court:"orem", chain:"demo", desc:"A line.", folders:[{name:"F", claims:[1], folders:[]}], relations:[{from:3,to:9,type:"part"}]});
const V = new Set([1,2,3,4,5,6,7,8,9,10,11]);
const run = (mut)=>{ const r=base(); mut&&mut(r); return cleanCuration(r,"orem",V); };

// acceptance
ok("clean base accepted", run().errs.length===0);
// rejections, rule by rule
ok("wrong version", run(r=>r.kourtCuration=2).errs.length>0);
ok("wrong court", run(r=>r.court="ledger").errs.length>0);
ok("desc >240", run(r=>r.desc="x".repeat(241)).errs.length>0);
ok("desc multi-paragraph", run(r=>r.desc="a\nb").errs.length>0);
ok("folder name empty", run(r=>r.folders[0].name="  ").errs.length>0);
ok("folder name >60", run(r=>r.folders[0].name="x".repeat(61)).errs.length>0);
ok("claim in two folders", run(r=>r.folders.push({name:"G",claims:[1],folders:[]})).errs.length>0);
ok("non-integer id", run(r=>r.folders[0].claims=[1.5]).errs.length>0);
ok("depth > 4", run(r=>{ let f=r.folders[0]; for(let i=0;i<4;i++){ f.folders=[{name:"d"+i,claims:[],folders:[]}]; f=f.folders[0]; } }).errs.length>0);
ok("bears without stance", run(r=>r.relations=[{from:6,to:9,type:"bears"}]).errs.length>0);
ok("stance on part", run(r=>r.relations=[{from:3,to:9,type:"part",stance:"supports"}]).errs.length>0);
ok("bad type", run(r=>r.relations=[{from:3,to:9,type:"blocks"}]).errs.length>0);
ok("from==to", run(r=>r.relations=[{from:3,to:3,type:"part"}]).errs.length>0);
ok("duplicate triple", run(r=>r.relations=[{from:3,to:9,type:"part"},{from:3,to:9,type:"part"}]).errs.length>0);
ok("two part-parents", run(r=>r.relations=[{from:3,to:9,type:"part"},{from:3,to:5,type:"part"}]).errs.length>0);
ok("part cycle", run(r=>r.relations=[{from:3,to:9,type:"part"},{from:9,to:3,type:"part"}]).errs.length>0);
ok("not an object", cleanCuration([], "orem", V).errs.length>0);
// warnings, not errors
const w1 = run(r=>{ r.extraKey=1; });
ok("unknown keys stripped + reported", w1.errs.length===0 && w1.warn.some(w=>w.includes("unknown keys stripped: extraKey")) && !("extraKey" in (w1.cur||{})));
const w2 = run(r=>r.relations=[{from:3,to:99,type:"part"}]);
ok("off-chain id warned, kept", w2.errs.length===0 && w2.warn.some(w=>w.includes("not on this chain")));
const w3 = run(r=>r.chain="sapphire-1");
ok("chain mismatch warned", w3.errs.length===0 && w3.warn.some(w=>w.includes("chain")));

// precedence: demo local ?? sample
CFG.mode='demo';
ok("demo default = sample", curationFor("orem").source==="sample" && curationFor("orem").folders.length===3);
const local = base();
store.set("cc.cur.demo.orem", JSON.stringify(cleanCuration(local,"orem",null).cur));
const cf = curationFor("orem");
ok("demo local overrides sample", cf.source==="local" && cf.folders.length===1 && cf.desc==="A line.");
store.del("cc.cur.demo.orem");
ok("clear restores sample", curationFor("orem").source==="sample");
// live: local ?? none
CFG.mode='live';
ok("live default = none", curationFor("orem")===null);
store.set("cc.cur.dev.orem", JSON.stringify(cleanCuration(local,"orem",null).cur));
ok("live local applies under chain key", curationFor("orem") && curationFor("orem").source==="local");
store.del("cc.cur.dev.orem");
CFG.mode='demo';

// idempotence: clean(clean(x)) byte-equal
const c1 = cleanCuration(base(),"orem",V).cur;
const c2 = cleanCuration(JSON.parse(JSON.stringify(c1)),"orem",V).cur;
ok("export→import idempotent", JSON.stringify(c1)===JSON.stringify(c2));

// label strings + curate-page copy present in source
ok("CUR_LABEL exact", src.includes('const CUR_LABEL = "your local curation — held in this browser, not on any chain"'));
/* THE FACTS, NOT THE SENTENCE. This pinned two exact phrases, so rewording the
   section for readers broke it while every fact it cared about survived. The
   moderator section must still say (a) these calls cost gas and no bond, and
   (b) a non-moderator is refused — however that ends up being phrased. */
ok("moderator section states the cost", /no deposit, no bond/.test(src));
ok("moderator section states who is refused",
   /refuses the transaction|refuses non-moderators/.test(src));
ok("...and cites no internal design document",
   !/(COURTS_STRUCTURE|MODERATION|PLAN)\.md[^"]{0,40}§/.test(
     src.slice(src.indexOf("Moderator actions"), src.indexOf("Moderator actions")+2000)));
ok("local section copy", src.includes("Nothing here writes to any chain"));
ok("map local captions", src.includes("your local curation overrides the sample — held in this browser, recorded nowhere") && src.includes("it overrides the chain's ${chainF.folders.length} folder"));
ok("no bulk sync button", !/sync to chain|publish curation/i.test(src));
ok("curate route + links", src.includes("/curate$")===false ? src.includes("curate$/") : true);
// The arrow moved into an aria-hidden span (a screen reader was reading
// "curate right arrow"), so pin the HREF — which is the fact — not the glyph.
ok("curate links on court+map", (src.match(/\/curate">curate/g)||[]).length>=2);
// §7.4 sweep on the curate page region
{
  const a=src.indexOf("/* --- curate:"); const b=src.indexOf("/* --- the map ---");
  const region=src.slice(a,b);
  ok("§7.4 clean on curate page", !/backing|redeem\b|profit|APR|price rises|worth/i.test(region));
}

// combined-critic fixes
ok("non-array relations rejected", run(r=>r.relations={"0":{from:3,to:9,type:"part"}}).errs.some(e=>e.includes("relations must be an array")));
ok("non-array folders rejected", run(r=>r.folders={}).errs.some(e=>e.includes("folders must be an array")));
ok("same-folder duplicate has its own message", run(r=>r.folders[0].claims=[1,1]).errs.some(e=>e.includes("listed twice in this folder")));
ok("cycle reported once", (()=>{ const r=run(x=>x.relations=[{from:3,to:5,type:"part"},{from:5,to:7,type:"part"},{from:7,to:3,type:"part"}]); return r.errs.filter(e=>e.includes("cycle")).length===1; })());
ok("astronomical ids rejected", run(r=>r.folders[0].claims=[1e21]).errs.length>0 && run(r=>r.relations=[{from:1e21,to:9,type:"part"}]).errs.length>0);

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
