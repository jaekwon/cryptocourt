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
  // FolderTree is the shape read: "id:parent:flags" per folder, one round trip
  // instead of three each. FTREE lets a test say what the chain's tree looks
  // like; the default is the flat one every existing case here assumed, so the
  // pre-nesting expectations still mean what they meant.
  if(/FolderTree/.test(expr)){
    if(global.FTREE === null) return `("" string)`;   // a realm without the read
    if(global.FTREE) return `("${global.FTREE}" string)`;
    const rows=[]; for(let i=1;i<=global.FCOUNT;i++) rows.push(`${i}:0:-`);
    return `("${rows.join(",")}" string)`;
  }
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
// chainFolders reads FolderTree through unesc now, so the harness needs the real
// one rather than a stand-in — a stub that unescaped differently would test the
// stub.
code += slice('function unesc(', '/* Untrusted text') + '\n';
code += 'async function inChunks(items, size, fn){ const out=[]; for(let i=0;i<items.length;i+=size) out.push(...await Promise.all(items.slice(i,i+size).map(fn))); return out; }\n';
code += slice('const CURATION_V', '/* ------').replace('const CURATION_V','var CURATION_V');
code += slice('const CHAIN_FOLDER_CAP', '/* ======').replace('const CHAIN_FOLDER_CAP','var CHAIN_FOLDER_CAP');
code += slice('function resolveFolderPath(', 'function folderMeta(');
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
  // 2 + 2F now: FolderCount, FolderTree, then name+items per folder. The extra
  // read is the whole point of FolderTree — the parent, retired and purged bits
  // it carries would otherwise be three MORE reads per folder, 300 at the cap.
  // Pinned because a read count is the one cost a client can regress silently.
  ok("read count = 2 + 2F", CALLS.length===2+2*3);
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
  // F5 was a grep for the guard's exact spelling, which reformatting broke while
  // the guard still worked. It is a CALL now: the resolver is a function rather
  // than a hundred lines inside a view, so the property can be asked for
  // directly instead of pattern-matched in source.
  {
    const chainF = {source:"chain", folders:[{fid:1, name:"One", folders:[{fid:2, name:"Two", folders:[]}]}]};
    ok("F5: exact fid match (no aliasing)",
       !resolveFolderPath(chainF,"01") && !resolveFolderPath(chainF,"1.2") && !!resolveFolderPath(chainF,"1"));
    // THE REGRESSION THAT SHIPPED: after nesting, this searched only the root
    // array, so a subfolder answered "no such folder" while the court page
    // linked to it. Asked of the resolver, which is where it lived.
    const kid = resolveFolderPath(chainF,"2");
    ok("a chain subfolder resolves", !!kid && kid.folder.fid===2);
    ok("and its trail is its ancestry", !!kid && kid.trail.length===2 && kid.trail[0].label==="One");
    // curation still addresses by position, because those folders have no ids
    const curF2 = {source:"local", folders:[{name:"A", folders:[{name:"B", folders:[]}]}]};
    ok("curation resolves by dotted index", resolveFolderPath(curF2,"0.0").folder.name==="B");
  }
  ok("F4: stale route comment gone", !src.includes("demo-only route — the overlay does not read on-chain folders yet"));

// NESTING FROM THE CHAIN. The realm answers the shape in one read; the overlay
// has to turn it into a tree without trusting it — a client that hangs on
// malformed state is a client a bad read can wedge.
  CFG.mode='live'; global.FCOUNT=3;
  global.FTREE = "1:0:-,2:1:-,3:0:-";
  const r = await chainFolders("orem");
  ok("chain folders nest", r.folders.length===2 && r.folders[0].folders.length===1);
  ok("the child hangs off its parent", r.folders[0].folders[0].fid===2);

  // A RETIRED FOLDER IS SKIPPED. The realm keeps its row so ids stay contiguous
  // for this very walk; it is struck from the tree, so it is not in the tree.
  global.FTREE = "1:0:-,2:1:r,3:0:-";
  const r2 = await chainFolders("orem");
  ok("a retired folder is not drawn", r2.folders.length===2 && r2.folders[0].folders.length===0);

  // A CYCLE CANNOT HANG THE CLIENT. The realm refuses to make one; this asserts
  // the overlay survives being told otherwise.
  global.FTREE = "1:2:-,2:1:-,3:0:-";
  const r3 = await chainFolders("orem");
  ok("a cyclic tree still terminates and keeps every folder",
     r3.folders.length + r3.folders.reduce((n,f)=>n+f.folders.length,0) === 3);

  // A SUBFOLDER IS REACHABLE BY ITS OWN ID, and this is the case the harness
  // did NOT have when nesting landed: chainFolders started returning roots, the
  // route resolver still searched the root array with .find(), and every chain
  // subfolder answered "No such folder" while the court page linked to it. The
  // list rendered correctly the whole time, which is why reading the row's label
  // proved nothing — the link had to be followed.
  global.FTREE = "1:0:-,2:1:-,3:0:-";
  const r5 = await chainFolders("orem");
  const kid = r5.folders[0].folders[0];
  ok("a subfolder keeps its own fid, not a positional path", kid && kid.fid===2);
  const findById = (list, fid) => {
    for(const x of list){
      if(x.fid===fid) return x;
      const hit = x.folders && x.folders.length && findById(x.folders, fid);
      if(hit) return hit;
    }
    return null;
  };
  ok("a subfolder is findable in the tree, not just among the roots",
     !!findById(r5.folders, 2) && !r5.folders.some(f=>f.fid===2));

  // ROW ORDER IS THE CURATOR'S ORDER. OrderFolders places siblings on chain and
  // FolderTree emits them in that order — so the client must DRAW them in the
  // order it read. This is the half that was missing: chainFolders parsed the
  // tree into a Map and then built its fetch list with `for(i=1;i<=F;i++)`,
  // which is id order, so the sequence survived the read and died one line later.
  global.FCOUNT=3; global.FTREE="3:0:-,1:0:-,2:0:-";
  const ord = await chainFolders("orem");
  ok("chain folders are drawn in the order the realm sent them",
     ord.folders.map(f=>f.fid).join(",")==="3,1,2");

  // A row the tree did not name is still drawn, after the ordered ones. Dropping
  // it would make a malformed or missing row invisible rather than merely last,
  // which is how a court loses a folder to a parse slip.
  global.FCOUNT=3; global.FTREE="3:0:-,1:0:-";
  const gap = await chainFolders("orem");
  ok("an id the tree never named is drawn last, not dropped",
     gap.folders.map(f=>f.fid).join(",")==="3,1,2");

  // AND A REALM WITHOUT THE READ still gets the flat list it always got.
  global.FCOUNT=3;
  global.FTREE = null;
  const r4 = await chainFolders("orem");
  ok("no FolderTree degrades to a flat list", r4.folders.length===3);
  global.FTREE = undefined; CFG.mode='demo';

  // THE SUMMARY GOES LAST, and it had not. It sat just after the "F4" line with
  // process.exit under it, so the nine assertions below — the whole NESTING FROM
  // THE CHAIN block — were unreachable and had never run once. The block was
  // appended after the summary rather than before it, which is invisible on
  // review: the file reads top to bottom and every one of those lines looks live.
  //
  // Those nine cover chain nesting, which is exactly where a regression shipped
  // this week: subfolders became unreachable while the court page went on linking
  // to them. The tests for it existed and could not have caught it.
  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
