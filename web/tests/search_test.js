// D2 harness: qPredicate table, parseJump grammar, qCaption verbatim per mode,
// data-q stamping, structural checks.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice } = require("./srcslice");
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo' };
global.isLive = ()=> CFG.mode==='live';
let code = '';
code += slice('function esc(', '\n');
code += slice('function fmtN(', 'function ugnot(');
code += slice('function qPredicate(', 'let QCTX').replace('let QCTX','');
code += slice('function mapCountLine(', '\nfunction mapSvg(');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// predicate
ok("case-insensitive substring", qPredicate("#4 Q3 City Revenue", "city rev"));
ok("id matches", qPredicate("#4 Q3 city revenue", "#4") && qPredicate("#40 other", "#4"));
ok("empty query matches all", qPredicate("anything", "  "));
ok("no match", !qPredicate("#4 Q3 city revenue", "bridge"));

// jump grammar
ok("bare 7 scoped", JSON.stringify(parseJump("7","orem"))===JSON.stringify({slug:"orem",id:7,bare:true}));
ok("#7 scoped", parseJump("#7","orem").id===7);
ok("orem/7", JSON.stringify(parseJump("orem/7",null))===JSON.stringify({slug:"orem",id:7,bare:false}));
ok("orem 7 (space)", parseJump("orem 7",null).slug==="orem");
ok("bare on directory keeps null slug", parseJump("7",null).slug===null);
ok("reject 0", parseJump("0","orem")===null);
ok("reject decimals", parseJump("1.5","orem")===null);
ok("reject leading zeros", parseJump("07","orem")===null);
ok("reject junk", parseJump("7x","orem")===null && parseJump("orem/7x",null)===null);

// captions (canonical family)
ok("idle live court", qCaption({mode:"idle",demo:false,kind:"claim titles",loaded:50,total:214})==="searches the 50 loaded claim titles of 214 — older claims live on the docket pages");
/* A LIVE COURT THAT IS ALL LOADED MUST NOT SEND ANYBODY AWAY. Reported from the
   map as «newest 11 of 11 shown — older claims live on the docket pages»: at
   11 of 11 there are no older claims and nothing is on another page, so the
   clause is an instruction to go looking for something that is already on
   screen. The demo branch had tested this all along; the live branch had not,
   and there was no case here for loaded === total to notice. */
ok("idle live court, everything loaded",
   qCaption({mode:"idle",demo:false,kind:"claim titles",loaded:11,total:11})
   === "searches all 11 claim titles");
ok("...and it does not promise more elsewhere",
   !/older claims live/.test(qCaption({mode:"idle",demo:false,kind:"claim titles",loaded:11,total:11})));

// The map's own line, the one that was reported. Three cases, because the bug
// was that only two of them existed.
ok("map, live and truncated, names the window and where the rest are",
   mapCountLine(false, 50, 214) === "newest 50 of 214 shown — older claims live on the docket pages");
ok("map, live and complete, says so without sending anybody away",
   mapCountLine(false, 11, 11) === "all 11 claims shown");
ok("...and carries no docket-page promise",
   !/older claims live/.test(mapCountLine(false, 11, 11)));
ok("map, demo, is unchanged", mapCountLine(true, 11, 11) === "11 claims, 11 shown");
// The boundary itself: one held back is still truncation.
ok("map, one claim short, is still truncated",
   /older claims live/.test(mapCountLine(false, 10, 11)));
ok("idle demo court", qCaption({mode:"idle",demo:true,kind:"claim titles",loaded:11,total:11})==="searches all 11 claim titles — the sample is complete");
ok("idle live directory", qCaption({mode:"idle",demo:false,kind:"court names",loaded:32,total:214})==="searches the 32 loaded court names — 182 more are not loaded; page older ›");
ok("idle demo directory", qCaption({mode:"idle",demo:true,kind:"court names",loaded:2,total:2})==="searches all 2 court names — the sample is complete");
ok("active", qCaption({mode:"active",matches:17,loaded:50,q:"snow"})==='17 of 50 loaded titles match "snow" · newest first');
ok("active directory tail", qCaption({mode:"active",matches:1,loaded:32,q:"or",orderTail:" · ranked by GNOT burned"}).endsWith("· ranked by GNOT burned"));
ok("zero live", qCaption({mode:"zero",demo:false,q:"snow",loaded:50,total:214})==='no loaded title matches "snow" — 164 older claims were never loaded; browse the docket pages');
ok("zero demo", qCaption({mode:"zero",demo:true,q:"snow",loaded:11,total:11})==='no title matches "snow" — the sample is complete');

// structure in source
ok("docket rows stamped data-q", src.includes('data-q="${esc("#"+c.id+" "+c.title)}"'));
ok("directory rows stamped data-q", src.includes('data-q="${esc("/"+c.slug+" "+c.name)}"'));
ok("qbar reuses addrbar", src.includes('class="addrbar qbar"'));
ok("type=search input", src.includes('type="search"'));
ok("offp union render", src.includes("the search box sweeps everything THIS RENDER loaded"));
ok("qhide class-only toggling", src.includes('classList.toggle("qhide"'));
ok("replaceState (no refetch)", src.includes('history.replaceState(null, "", "#"+path+tail)'));
ok("slash focuses / escape clears", src.includes('ev.key==="/"') && src.includes('ev.key==="Escape"'));
ok("directory bare-number note", src.includes("name a court — orem/${j.id}"));
ok("free in-scope validation", src.includes("no claim #${j.id} — this court has"));
ok("statusText never in data-q", !src.includes('c.statusText}" data-q') && !src.includes('data-q="${esc("#"+c.id+" "+c.title+" "+c.statusText'));
ok("§7.4 clean", !/backing|redeem\b|profit|APR/i.test(slice('function qPredicate(','let QDEB')));


// D2 critic fixes (round 79)
ok("C5: applyQ threads kind to zero+active", src.includes('kind:QCTX.kind, orderTail:QCTX.orderTail') && src.includes('q, kind:QCTX.kind, loaded:QCTX.loaded'));
ok("C1: offp scoped under .docket", src.includes(".docket .offp{display:none}") && !src.includes("\n.offp{display:none}"));
ok("C1: reveal outranks the hide", src.includes(".qactive .docket .offp:not(.qhide){display:grid}"));
ok("C2: court qbar precedes its section", src.indexOf('qBarHtml("title or #id"') < src.indexOf('<section data-qsec${foldersSec'));
ok("C2: directory qbar precedes Featured", src.indexOf('qBarHtml("court name or orem/7"') < src.indexOf('sec-h">Featured'));
ok("C3: Enter flushes the debounce", src.includes("clearTimeout(QDEB); QDEB=0;"));
ok("C4: QCTX totals = route totalClaims", src.includes("total:totalClaims, slug, totalClaims"));
ok("C5: zero caption speaks in names (live)", qCaption({mode:"zero",demo:false,kind:"court names",q:"x",loaded:32,total:214})==='no loaded name matches "x" — 182 more courts are not loaded; page older ›');
ok("C5: zero caption speaks in names (demo)", qCaption({mode:"zero",demo:true,kind:"court names",q:"x",loaded:2,total:2})==='no name matches "x" — the sample is complete');
ok("C5: active caption speaks in names", qCaption({mode:"active",matches:1,loaded:32,q:"or",kind:"court names",orderTail:" · ranked by GNOT burned"})==='1 of 32 loaded names match "or" · ranked by GNOT burned');
ok("C6: uppercase slug jumps", JSON.stringify(parseJump("OREM/7",null))===JSON.stringify({slug:"orem",id:7,bare:false}));
ok("C6: zero-pad rejected in slug form too", parseJump("orem/007",null)===null);
ok("C7: stats-hidden rows stop matching", src.includes('row.removeAttribute("data-q")'));

// D6-critic: the sample stops certifying completeness where it hides claims
ok("idle demo, hidden gap", qCaption({mode:"idle",demo:true,kind:"claim titles",loaded:2,total:5})==="searches the 2 loaded claim titles of 5 — hidden claims are omitted");
ok("zero demo, hidden gap", qCaption({mode:"zero",demo:true,q:"fire",loaded:2,total:5})==='no loaded title matches "fire" — 3 hidden claims omitted; their pages still answer by id');
ok("idle demo, complete sample unchanged", qCaption({mode:"idle",demo:true,kind:"claim titles",loaded:11,total:11})==="searches all 11 claim titles — the sample is complete");
console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
