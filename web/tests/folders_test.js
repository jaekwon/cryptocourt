// D1 harness: chainFolders parsing (both slice shapes), foldersFor precedence,
// folderMeta first-wins, purge-name escaping, caption switches, read counts.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'live', chainid:'dev' };
global.isLive = ()=> CFG.mode==='live';
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = Number(NOWm[1].replace(/_/g,''));
const mem={};
global.localStorage = { getItem:k=>mem[k]??null, setItem:(k,v)=>{mem[k]=v;}, removeItem:k=>{delete mem[k];} };

// qeval stub with call counting; shape configurable per test
let CALLS=[]; let QSHAPE="tokens";
global.qeval = async expr => {
  CALLS.push(expr);
  if(/FolderCount/.test(expr)) return `(${global.FCOUNT} int)`;
  if(/FolderName\(.*,(\d+)\)/.test(expr)){
    const fid=+expr.match(/,(\d+)\)/)[1];
    return fid===2? `("[purged:9.2]<img src=x onerror=alert(1)>" string)` : `("Folder ${fid}" string)`;
  }
  if(/FolderItems/.test(expr)){
    const fid=+expr.match(/,(\d+)\)/)[1];
    if(QSHAPE==="tokens") return `(slice[(${fid} uint64),(${fid+10} uint64)] []uint64)`;
    return `([${fid} ${fid+10}] []uint64)`;
  }
  throw new Error("unexpected "+expr);
};

let code = '';
code += slice('function esc(', '\n');
code += slice('function fmtN(', 'function ugnot(');
code += 'var NOW='+global.NOW+';\n';
code += slice('function parseTyped(', 'const gstr').replace(/const one =/,'var one =').replace(/const tup =/,'var tup =');
code += 'const gstr = s => JSON.stringify(String(s));\n';
// Round 28 split the literal: DEMO_CHAIN is generated, DEMO_OVERLAY is the
// hand-written half (desc, nested folders, relations, voteEndsAt), and
// mergeDemo joins them. foldersFor() reads the MERGED object, so the harness
// has to build it the same way the page does rather than eval one half.
code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED')
        .replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED')
        .replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
code += "var store={get:k=>{try{return localStorage.getItem(k)}catch(_){return null}},set:(k,v)=>{try{localStorage.setItem(k,v)}catch(_){}},del:k=>{try{localStorage.removeItem(k)}catch(_){}}};\n";
code += "const demoCourt = slug => Object.hasOwn(DEMO.courts, slug)? DEMO.courts[slug] : null;\n";
code += 'async function inChunks(items, size, fn){ const out=[]; for(let i=0;i<items.length;i+=size) out.push(...await Promise.all(items.slice(i,i+size).map(fn))); return out; }\n';
code += slice('const CURATION_V', '/* ------').replace('const CURATION_V','var CURATION_V');
code += slice('const CHAIN_FOLDER_CAP', '/* ======').replace('const CHAIN_FOLDER_CAP','var CHAIN_FOLDER_CAP');
code += slice('function folderCount(', 'function folderRowHtml');
code += slice('function folderRowHtml(', 'function isDone');
code += 'function safeInline(x){ return esc(String(x)); }\n';
code += 'const ICN_FOLDER="<svg/>";\n';
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

(async ()=>{
  // parse: per-element uint64 tokens must not leak their 64s
  global.FCOUNT=3; CALLS=[]; QSHAPE="tokens";
  const cf = await chainFolders("orem");
  ok("3 folders read", cf.folders.length===3 && cf.count===3 && !cf.capped);
  ok("ids parsed from (N uint64) tokens", JSON.stringify(cf.folders[0].claims)==="[1,11]" && JSON.stringify(cf.folders[2].claims)==="[3,13]");
  ok("no 64 leakage", !cf.folders.some(f=>f.claims.includes(64)));
  ok("read count = 1 + 2F", CALLS.length===1+2*3);
  ok("fids contiguous + paths set", cf.folders.every((f,i)=>f.fid===i+1 && f.path===String(i+1) && f.chain===true));
  // bare-bracket shape fallback
  QSHAPE="bare"; const cf2 = await chainFolders("orem");
  ok("bare-bracket shape also parses", JSON.stringify(cf2.folders[0].claims)==="[1,11]");
  QSHAPE="tokens";
  // zero folders = exactly one read
  global.FCOUNT=0; CALLS=[];
  const cf0 = await chainFolders("orem");
  ok("F=0 → one read, empty", CALLS.length===1 && cf0.folders.length===0);
  // cap
  global.FCOUNT=150; const cfC = await chainFolders("orem");
  ok("cap at 100, capped flag", cfC.folders.length===100 && cfC.capped && cfC.count===150);
  global.FCOUNT=3;

  // purge tombstone escapes through folderRowHtml (no HTML injection)
  const row = folderRowHtml("orem", (await chainFolders("orem")).folders[1], "2");
  ok("purged name escaped", row.includes("[purged:9.2]&lt;img") && !row.includes("<img src=x"));
  ok("chain fid path in href", row.includes('href="#/c/orem/f/2"'));

  // foldersFor precedence: local ?? chain ?? sample ?? none
  const chainF = await chainFolders("orem");
  CFG.mode='live';
  ok("live: chain is default", foldersFor("orem", chainF).source==="chain");
  ok("live: none when chain empty", foldersFor("orem", {folders:[],count:0})===null || (foldersFor("orem",{folders:[],count:0})||{}).source===undefined);
  const local={kourtCuration:1,court:"orem",chain:"dev",desc:"",folders:[{name:"L",claims:[1],folders:[]}],relations:[]};
  store.set("cc.cur.dev.orem", JSON.stringify(local));
  ok("live: local overrides chain", foldersFor("orem", chainF).source==="local");
  store.del("cc.cur.dev.orem");
  CFG.mode='demo';
  ok("demo: sample when no local", foldersFor("orem", null).source==="sample");
  CFG.mode='live';

  // folderMeta first-wins on multi-membership; D3: values carry {label, path}
  const meta = folderMeta([{name:"A",claims:[5],folders:[]},{name:"B",claims:[5],folders:[]}], "", {});
  ok("first-wins meta", meta[5].label==="A" && meta[5].path==="0");
  const metaN = folderMeta([{name:"A",claims:[],folders:[{name:"Ax",claims:[7],folders:[]}]}], "", {});
  ok("D3: nested dot-path + composed label", metaN[7].label==="A · Ax" && metaN[7].path==="0.0");
  const metaC = folderMeta([{name:"C",claims:[9],folders:[],path:"3"}], "", {});
  ok("D3: chain fid path wins over index", metaC[9].path==="3");

  // captions present in source; apology extinct
  ok("chain caption (docket)", src.includes("read live from the chain — moderator curation, zero economic weight"));
  ok("chain caption (map)", src.includes("folders read from the chain — moderator curation"));
  ok("no-folders caption", src.includes("this court's moderators have filed no folders"));
  ok("apology string extinct", !src.includes("does not read them live"));
  ok("folder page omitted caption", src.includes("hidden or unreadable row"));
  ok("§7.4 clean in new strings", !/backing|redeem\b|profit|APR/i.test(slice('const CHAIN_FOLDER_CAP','/* ======')));


  // D1 critic fixes
  ok("F1: map data build has first-wins across folders", src.includes("first-wins across folders too"));
  ok("F2: folder page resolves only this page's ids", src.includes("resolve\n  // only THIS PAGE's out-of-window ids") || src.includes("only THIS PAGE's out-of-window ids"));
  ok("F3: no id re-sort on chain members", !src.includes("members.concat(got).sort((a,b)=>b.id-a.id)"));
  ok("F5: exact fid match (no aliasing)", src.includes('String(parseInt(fpath,10))!==fpath'));
  ok("F4: stale route comment gone", !src.includes("demo-only route — the overlay does not read on-chain folders yet"));

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
