// D1 harness: chainFolders parsing (both slice shapes), foldersFor precedence,
// folderMeta first-wins, purge-name escaping, caption switches, read counts.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice } = require("./srcslice");
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
// siteHost() reads it, and a folder's picture resolves to https://<host>/m/<sha>.
global.location = { protocol:"https:", host:"kourt.xyz", origin:"https://kourt.xyz" };
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
    // FOUR FIELDS BY DEFAULT, which is what the realm emits: id:parent:flags:bornOf.
    // A three-field row is an OLDER realm and is exercised on purpose below.
    const rows=[]; for(let i=1;i<=global.FCOUNT;i++)
      rows.push(`${i}:0:-:${(global.FBORN||{})[i]||0}`);
    return `("${rows.join(",")}" string)`;
  }
  if(/FolderName\(.*,(\d+)\)/.test(expr)){
    const fid=+expr.match(/,(\d+)\)/)[1];
    return fid===2? `("[purged:9.2]<img src=x onerror=alert(1)>" string)` : `("Folder ${fid}" string)`;
  }
  /* THE TYPED SHAPE, deliberately: "(6 uint64)" is what a node actually answers,
     and "uint64" ENDS IN 64 — a reader that strips non-digits turns folder 6's
     claim into 664. The trap is documented in uint64List and this is the read
     that walks into it. FBORN says which folder was affirmed and by whom. */
  if(/SetBornOf/.test(expr)){
    const fid=+expr.match(/,(\d+)\)/)[1];
    const m = global.FBORN || {};
    return `(${m[fid] || 0} uint64)`;
  }
  if(/FolderItems/.test(expr)){
    const fid=+expr.match(/,(\d+)\)/)[1];
    if(QSHAPE==="tokens") return `(slice[(${fid} uint64),(${fid+10} uint64)] []uint64)`;
    return `([${fid} ${fid+10}] []uint64)`;
  }
  // The shape encodeMedia writes for a folder's one picture: one line of JSON,
  // one item. FIMG lets a case say the read failed or the realm is too old.
  if(/FolderImage/.test(expr)){
    if(global.FIMG === null) throw new Error("no such read");
    return `("${(global.FIMG || `[{\\"kind\\":\\"img\\",\\"sha256\\":\\"${"a".repeat(64)}\\",\\"mime\\":\\"image/png\\",\\"w\\":328,\\"h\\":88,\\"bytes\\":796,\\"caption\\":\\"\\",\\"mirrors\\":[]}]`)}" string)`;
  }
  throw new Error("unexpected "+expr);
};

let code = '';
code += slice('function esc(', '\n');
// the affirmed-claim walk, so its recursion is RUN rather than read: it used to
// be two byte-identical copies and a source pin that had to name both
code += slice('function bornClaimIds(', 'function folderCount(');
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
code += 'const ICN_EYE_OPEN="<svg/>", ICN_EYE_SHUT="<svg/>";\n';   // the row needs the marks to exist, not to be drawn
code += slice('function folderCount(', 'function folderRowHtml');
code += slice('function folderRowHtml(', 'function isDone');
code += 'function safeInline(x){ return esc(String(x)); }\n';
// F1 asks mapLayout directly now, so the map's own code has to be here.
code += slice('const MAPK', '/* The join panel').replace('const MAPK','var MAPK');
code += 'function phaseClass(t){ return {short:"open"}; }\n';
// A FOLDER'S PICTURE comes back through the same two functions a claim node's
// thumbnail uses, so the real ones are loaded rather than stubbed: a stub that
// resolved a mirror, or resolved anything without a sha256, would test the stub
// and pass while the page leaked every reader's address to a filer-chosen host.
const M = require(require('path').join(__dirname,'..','media.js'));
global.mediaParse = M.mediaParse; global.mediaNodeThumb = M.mediaNodeThumb;
code += slice('function siteHost(', 'const store');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

(async ()=>{
  // parse: per-element uint64 tokens must not leak their 64s
  global.FCOUNT=3; CALLS=[]; QSHAPE="tokens";
  const cf = await chainFolders("orem");
  ok("3 folders read", cf.folders.length===3 && cf.count===3 && !cf.capped);
  ok("ids parsed from (N uint64) tokens", JSON.stringify(cf.folders[0].claims)==="[1,11]" && JSON.stringify(cf.folders[2].claims)==="[3,13]");
  ok("no 64 leakage", !cf.folders.some(f=>f.claims.includes(64)));
  /* 2 + 2F: FolderCount, FolderTree, then name + items per folder. The tree read
     is the whole point of FolderTree — the parent, retired and purged bits it
     carries would otherwise be three MORE reads per folder, 300 at the cap.
     Pinned because a read count is the one cost a client can regress silently.
     IT WAS 2 + 3F, and this file recorded that third read as a DEBT rather than
     a shape: bornOf is a per-folder bit, and the tree row is what exists to
     carry per-folder bits — the "i" flag beside it had already made the
     argument. It is a fourth field now and the read is gone, which is what the
     note here said would cost nothing.
     0 MEANS DECLARED, unchanged: a moderator's CreateFolder leaves bornOf zero
     and a set nobody voted for must not claim to have been affirmed. */
  ok("read count = 2 + 2F", CALLS.length===2+2*3);
  ok("fids contiguous + paths set", cf.folders.every((f,i)=>f.fid===i+1 && f.path===String(i+1) && f.chain===true));
  /* WHICH CLAIM AFFIRMED THE SET, read back off the chain and parsed with the
     helper rather than by hand. 664 is the failure this asserts against: it is
     what "(6 uint64)" becomes when a reader strips non-digits, and the tree is
     full of that mistake's cousins. */
  global.FBORN={2:6}; CALLS=[]; const cfb = await chainFolders("orem");
  ok("a set carries the claim that affirmed it", cfb.folders[1].born===6, JSON.stringify(cfb.folders[1].born));
  ok("...and the type name's own 64 does not leak into it",
     cfb.folders[1].born!==664 && !cfb.folders.some(f=>f.born===664));
  ok("...while a declared set carries none",
     cfb.folders[0].born===undefined && cfb.folders[2].born===undefined,
     JSON.stringify(cfb.folders.map(f=>f.born)));
  global.FBORN=undefined;
  /* A SET NESTED IN ANOTHER IS STILL BORN OF A CLAIM — mod:newset takes a
     parentID — so the walk that collects affirmed claims has to recurse, or a
     subset's claim keeps its duplicate row while a root set's loses it.
     PINNED IN SOURCE, because the offline sample has no nested born set to walk:
     giving one to annex or orem would move the fixtures three other harnesses
     measure, which is a worse trade than naming the gap here. The recursion is
     one line and this is what watches it. */
  /* THE WALK IS A FUNCTION NOW, so this runs it instead of reading it. It was a
     source pin over two byte-identical copies — the docket's and the map's — and
     the pin had to name both, because one that said "the" walk would have
     watched whichever came first in the file. Extracting the copies made the
     behaviour reachable, so the pin becomes a test.
     NESTED IS THE CASE THAT MATTERS: mod:newset takes a parentID, so a subset is
     born of a claim too, and a walk that stopped at the roots would leave that
     claim duplicated while a root set's claim was not. The offline sample has no
     nested born set to render — giving it one would move fixtures three other
     harnesses measure — but the function can simply be handed one. */
  ok("the affirmed-claim walk finds a root set's claim", (()=>{
    const got = bornClaimIds([{name:"a", born:7, folders:[]}]);
    return got.size === 1 && got.has(7);
  })());
  ok("...and one nested inside another", (()=>{
    const got = bornClaimIds([{name:"a", born:7, folders:[
      {name:"b", born:9, folders:[{name:"c", born:11, folders:[]}]}]}]);
    return got.size === 3 && got.has(7) && got.has(9) && got.has(11);
  })());
  ok("...and claims nothing for a set nobody voted for", (()=>{
    const got = bornClaimIds([{name:"a", folders:[{name:"b", folders:[]}]}]);
    return got.size === 0;
  })());
  ok("...and survives an empty or absent tree",
     bornClaimIds([]).size === 0 && bornClaimIds(undefined).size === 0
     && bornClaimIds(null).size === 0);
  // bare-bracket shape fallback
  QSHAPE="bare"; const cf2 = await chainFolders("orem");
  ok("bare-bracket shape also parses", JSON.stringify(cf2.folders[0].claims)==="[1,11]");
  QSHAPE="tokens";
  // ---- a folder's one picture (owner ruling, CLAIM_MEDIA §10.11) ----------
  // The "i" flag in FolderTree is the whole economy of this feature: without it
  // a map draw would ask FolderImage per folder, a hundred at the cap, for a
  // field most folders never set. So the read count is pinned in BOTH
  // directions — paid where there is a picture, not paid where there is not.
  global.FCOUNT=3; global.FTREE="1:0:-:0,2:0:i:0,3:0:-:0"; global.FIMG=undefined; CALLS=[];
  const cfi = await chainFolders("orem");
  ok("only the flagged folder is asked for a picture",
     CALLS.filter(e=>/FolderImage/.test(e)).length===1 && /FolderImage\("orem",2\)/.test(CALLS.find(e=>/FolderImage/.test(e))));
  // ...and the picture is still the only read that is CONDITIONAL: 3F is the
  // floor every folder pays, plus one for the single folder the tree flagged.
  ok("read count = 2 + 2F + 1 picture", CALLS.length===2+2*3+1);
  ok("the flagged folder carries an archive URL",
     cfi.folders[1].img==="https://kourt.xyz/m/"+"a".repeat(64));
  ok("the unflagged folders carry no picture", cfi.folders[0].img==="" && cfi.folders[2].img==="");
  // A MIRROR IS NOT GOOD ENOUGH HERE. mediaNodeThumb refuses anything without an
  // archive copy, because a map draw is fifty boxes fanning out to hosts the
  // filer picked. An item with mirrors and no sha256 must come back empty.
  global.FIMG='[{\\"kind\\":\\"img\\",\\"sha256\\":\\"\\",\\"mime\\":\\"image/png\\",\\"w\\":8,\\"h\\":8,\\"bytes\\":9,\\"caption\\":\\"\\",\\"mirrors\\":[\\"https://i.imgur.com/x.png\\"]}]';
  const cfm = await chainFolders("orem");
  ok("a mirror-only picture is not drawn on the map", cfm.folders[1].img==="");

  // ---- a realm that predates bornOf in the row ----------------------------
  // THE FALLBACK IS NOT DECORATION. bornOf moved into the tree row to kill one
  // read per folder, but a realm deployed before that answers three fields, and
  // a client that treated the missing field as ZERO would tell every set on that
  // chain it was never affirmed — a wrong answer, quietly, rather than a slower
  // right one. `born === null` means the tree did not say; only then is the read
  // spent, and the answer is the same either way.
  global.FCOUNT=2; global.FTREE="1:0:-,2:0:-"; global.FBORN={1:6}; global.FIMG=undefined; CALLS=[];
  const cfo = await chainFolders("orem");
  ok("a three-field row still parses", cfo.folders.length===2);
  ok("...and bornOf is fetched, not assumed zero",
     CALLS.filter(e=>/SetBornOf/.test(e)).length===2);
  ok("...to the same answer the row would have given",
     cfo.folders[0].born===6 && !cfo.folders[1].born);
  ok("read count falls back to 2 + 3F", CALLS.length===2+3*2);

  // ...and with the field present, the read is not spent at all.
  global.FTREE="1:0:-:6,2:0:-:0"; CALLS=[];
  const cfn = await chainFolders("orem");
  ok("a four-field row spends no SetBornOf read",
     CALLS.filter(e=>/SetBornOf/.test(e)).length===0);
  ok("...and carries the same bornOf the read would have returned",
     cfn.folders[0].born===6 && !cfn.folders[1].born);
  global.FBORN=undefined;
  // A purged slot: encodeMedia keeps the position and drops everything else.
  global.FIMG='[{\\"kind\\":\\"img\\",\\"purged\\":true}]';
  const cfp = await chainFolders("orem");
  ok("a purged picture is not drawn", cfp.folders[1].img==="");
  // The read itself failing must not take the folder with it — the name and the
  // claims are the page, and the picture is the decoration.
  global.FIMG=null;
  const cff = await chainFolders("orem");
  ok("a failed picture read still yields the folder",
     cff.folders[1].name==="[purged:9.2]<img src=x onerror=alert(1)>" && cff.folders[1].img==="" && !cff.folders[1].failed);
  global.FTREE=undefined; global.FIMG=undefined;

  // Zero folders costs TWO reads that go together, and never the per-folder
  // fan-out. It used to be one, and the second is a deliberate trade: the count
  // and the tree are now asked at the same time, because FolderTree never needed
  // the count and waiting for it put two round trips in a row ahead of every
  // folder name. A court with no folders therefore pays one query it does not
  // use — and no extra WALL TIME, since it is in flight beside the count.
  // What must not come back is the loop: no FolderName or FolderItems here.
  global.FCOUNT=0; CALLS=[];
  const cf0 = await chainFolders("orem");
  ok("F=0 → the count and the tree, together, and nothing per folder",
     CALLS.length===2 && cf0.folders.length===0
     && !CALLS.some(c=>/FolderName|FolderItems/.test(c)));
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
  //
  // F1 WAS A GREP for the comment above the map's dedup, and the radial layout
  // moved that dedup out of the view and into mapTree — so the grep failed while
  // the property held. Same lesson F5 below already records: ask the code, do not
  // pattern-match its prose. A claim in two folders is drawn ONCE, and the second
  // folder gets an "also filed here" spoke instead of a second copy.
  {
    const two = [{name:"By evidence", claims:[7], folders:[]},
                 {name:"Cross-cut", claims:[7], folders:[]}];
    const d = {folders:two, all:[7], claims:{7:{title:"One claim, filed twice.", statusText:"open — stake YES or NO"}},
               relations:[], courtName:"Orem Truth Court"};
    const L = mapLayout(d, "ids");
    ok("F1: a claim in two folders is drawn once", L.nodes.length===1);
    ok("F1: and the second folder is joined to it anyway",
       L.spokes.filter(s=>s.kind==="also").length===1);
  }
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

  // COPY THAT WENT STALE ONCE ALREADY. The page said the chain "is flat" for a
  // while after folders started nesting; it said supersedes was "in no spec"
  // after the spec was written. Both were true when typed and both survived the
  // thing that falsified them, because prose has no test unless somebody writes
  // one. This is that, for the second of them.
  ok("the page no longer calls supersedes unspecified", !src.includes("in no spec"));

  // THE SUMMARY GOES LAST, and it had not. It sat just after the "F4" line with
  // process.exit under it, so the nine assertions below — the whole NESTING FROM
  // THE CHAIN block — were unreachable and had never run once. The block was
  // appended after the summary rather than before it, which is invisible on
  // review: the file reads top to bottom and every one of those lines looks live.
  //
  // Those nine cover chain nesting, which is exactly where a regression shipped
  // this week: subfolders became unreachable while the court page went on linking
  // to them. The tests for it existed and could not have caught it.
  /* THE FOLDER'S JUMP TO THE MAP rides the heading, not a paragraph below it.
     Asked for as: move it right of the name, and replace the arrow with a map
     icon "like starlight constellation routes".
     Source assertions, because this harness has no browser — the GEOMETRY (that
     it lands right of the seal, on the same line) is measured in the deploy
     screenshot rather than here, and this side pins the things a rename or a
     tidy-up would break: that the link is inside the h1 at all, and that the old
     paragraph is gone.

     THE ARROW CAME BACK, and this assertion used to forbid it. Reported as "map
     doesn't have an arrow" on /c/covid/f/4.
     The original request was to replace an arrow-ONLY affordance with the map's
     mark, and that reading held while this was the only jump of its kind. It
     stopped holding when the claim page grew the same jump and settled the house
     style at icon-noun-arrow — d3_test names it "the shared convention" and pins
     `${ICN_CONSTEL}map<span` there. So the two map links in this app read
     differently for no reason a reader could see, and the folder one was the odd
     one out. The icon is not the arrow and never was: it says WHICH view, and
     the arrow says there is one to go to. */
  ok("the folder's map jump is inside the heading",
     src.includes('<span class="seal">${esc(slug)}</span> `')
     && src.includes('<a class="hjump" href="#/c/${esc(slug)}/map?ffocus=${esc(fpath)}">${ICN_CONSTEL}map<span aria-hidden="true">→</span></a>'));
  ok("...and the paragraph it used to live in is gone",
     !src.includes('<p class="tacts" style="margin:0 0 10px"><a class="tlink" href="#/c/${esc(slug)}/map?ffocus='));
  /* Every map link, asserted against every other — one convention is only a
     convention if the surfaces that follow it are checked against each other.
     Pinning them apart is what let them drift.

     AND COUNTED AS AN EQUALITY, NOT AS A NUMBER. This read `=== 2` and so only
     ever described the two surfaces that had the icon on the day it was written.
     The court page's row and the curate page's row carried the same jump BARE,
     which is a third and fourth surface the assertion could not see: the two it
     did count still numbered two, so a bare "map→" shipped green. Reported as
     "the map→ doesn't have the map icon like other places do" on /c/covid.
     The invariant is not "there are N of them" — it is that no link whose noun
     is "map" is missing the mark. So the counts have to agree, whatever the
     fifth surface turns out to be. */
  {
    const jumps  = (src.match(/map<span aria-hidden="true">→<\/span>/g)||[]).length;
    const marked = (src.match(/\$\{ICN_CONSTEL\}map<span aria-hidden="true">→<\/span>/g)||[]).length;
    ok("...and every map jump carries the constellation, the noun and the arrow",
       jumps >= 4 && marked === jumps);
  }
  /* The arrow is decoration, not content: the link already reads "map", so a
     screen reader announcing "map right-arrow" describes the ornament. */
  ok("...with the arrow hidden from assistive tech on both",
     !/\$\{ICN_CONSTEL\}map→/.test(src));
  /* The icon is a constellation: routes drawn BEHIND stars, which in SVG means
     the stroked path is emitted before the circles. Asserted as an order, not
     just a presence — circles first would put the joins over the points and the
     thing stops reading as a star chart. */
  {
    const i = src.indexOf("const ICN_CONSTEL =");
    const decl = src.slice(i, src.indexOf("\n", i));
    ok("the constellation icon exists", i > 0 && decl.length > 60);
    ok("...with four stars", (decl.match(/<circle /g) || []).length === 4);
    ok("...joined by one route", (decl.match(/<path /g) || []).length === 1);
    ok("...routes drawn behind the stars", decl.indexOf("<path ") < decl.indexOf("<circle "));
    ok("...and it inherits the link's colour", !/#[0-9a-f]{3,6}/i.test(decl)
       && (decl.match(/currentColor/g) || []).length >= 2);
  }
  /* THE CHAIN'S LISTS RESOLVE A FOLDER FROM THE TREE, NOT FROM THE DOCKET.
     Still flaggable and Awaiting an answer are the realm's own lists and can
     name a claim this page never loaded — byId is the docket's window, foldOf
     is the whole court. Gating the lookup on byId would leave those rows with
     no folder, so a filter would drop them from every folder while the reader
     is looking straight at them. Pinned in source because the case needs a
     court whose chain list reaches past its first page, which the offline
     sample has no way to build. */
  ok("the chain lists take the folder from the tree, not the loaded window",
     src.includes("const fk = foldOf[r.id];")
     && /data-fold="\$\{esc\(fk && fk\.length\? fk\.join\(" "\) : "~none"\)\}"/.test(src));

  /* TWO RULES THE OFFLINE SAMPLE CANNOT PUT ON SCREEN, pinned here rather than
     left to a browser case that never runs.
     OFF-PAGE IS NOT SHOWN. The chain's lists drop a claim the docket above
     already lists, and an off-page row is rendered-and-hidden, not shown — so
     it must not count. Were it counted, turning to page 2 of a docket would
     quietly delete claims from the flaggable list, which is the one list that
     is supposed to reach past the page. No sample court paginates.
     THE DENOMINATOR IS THE CHAIN'S QUEUE. "2 of 50" is the list saying how much
     of the chain's queue it is showing; a bare "2" says nothing about the 48.
     It only differs from the plain figure when some rows were dropped or the
     queue runs past this page, and no sample court does either. */
  ok("off-page rows do not count as shown by the docket",
     src.includes("const onPage = new Set(rowsAll.filter(cl=>!cl.offp).map(cl=>cl.id));"));
  ok("the chain heading's denominator is the whole queue",
     src.includes("const rest = shown===total? String(shown) : `${fmtN(shown)} of ${fmtN(total)}`;")
     && /chainHead\(stripRows\.length, stripQ\.rows\.length\+\(stripQ\.more\|\|0\)\)/.test(src));

  console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
  process.exit(fail?1:0);
})();
