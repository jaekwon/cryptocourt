// D5 harness: clockLine table, the annex exemplar, demo mirrors, strip strings,
// opened-by, answer record, §7.4 sweep.
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
const BSm = src.match(/const BLOCK_SECS\s*=\s*([0-9_]+)/); global.BLOCK_SECS = Number(BSm[1].replace(/_/g,''));

let code = '';
code += slice('function esc(', '\n');
code += slice('function fmtN(', 'function ugnot(');
code += 'var NOW='+global.NOW+'; var BLOCK_SECS='+global.BLOCK_SECS+';\n';
code += slice('function wall(', 'function pctYes');
code += slice('/* The docket\'s impersonal clock', 'function pctYes');
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
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

// clockLine table
ok("disputed = sealed line, mode/height-blind", clockLine(null,"in dispute",null,null)==="a sealed vote is deciding — no close height is published" && clockLine(123,"in dispute",99,99)==="a sealed vote is deciding — no close height is published");
ok("answered ahead", clockLine(100,"answered",200,null).startsWith("settles undisputed at ≈block 200 — in ") && clockLine(100,"answered",200,null).endsWith(" unless disputed"));
ok("answered past", clockLine(300,"answered",200,null)==="the settle window has passed — anyone may settle it now");
ok("answered, no height read", clockLine(null,"answered",200,null)==="settles undisputed at ≈block 200");
ok("provisional ahead", clockLine(100,"provisional",null,150).startsWith("reopenable until ≈block 150 — in "));
ok("provisional past", clockLine(200,"provisional",null,150)==="the reopen window has closed — finalizable");
ok("open/settled rows get no clock", clockLine(100,"open",null,null)==="" && clockLine(100,"settled",null,null)==="");

// annex exemplar
ok("annex exists, tier 0, five claims", DEMO.courts.annex && DEMO.courts.annex.tier===0 && DEMO.courts.annex.claims.length===5);
// D6-3: the chain's policing lists
ok("annex/5 hidden AND answered (strip specimen)", DEMO.claims["annex/5"].hidden===true && DEMO.claims["annex/5"].phase==="answered");
ok("live parser reads all three sections", src.includes('"Needs review/.test(line)? "strip"') || src.includes('Needs review/.test(line)? "strip"'));
ok("strip rows outside data-sortable, folded in search", src.includes('<section data-qfold style="margin-top:22px"><div class="sec-h">Needs review'));
ok("strip caption keeps the chain sentence", src.includes("a claim hidden from the docket above still appears here while it can still be flagged."));
ok("pending caption verbatim", src.includes("Seeded and appeal claims that no one has answered yet"));
ok("overflow never labeled as the total", src.includes("the chain's page shows the nearest 50"));
ok("demoRender emits the strip sections", src.includes("## Needs review") && src.includes("## Awaiting an answer"));
// D6-2 moderation specimens
ok("annex/2 seeded specimen", DEMO.claims["annex/2"].seeded===true && !DEMO.claims["annex/2"].hidden);
ok("annex/3 hidden specimen", DEMO.claims["annex/3"].hidden===true && !DEMO.claims["annex/3"].redacted);
ok("annex/4 redacted stores only the gated title", DEMO.claims["annex/4"].redacted===true && DEMO.claims["annex/4"].title==="[text withheld]");
ok("demo listings omit hidden claims", src.includes(".filter(id=>!(DEMO.claims[slug+\"/\"+id]||{}).hidden)"));
ok("demoRender omits hidden claims too", src.includes('.filter(id=>!(DEMO.claims[parts[0]+"/"+id]||{}).hidden)'));
ok("banner precedence purged>redacted>hidden", src.indexOf("Removed on legal grounds") < src.indexOf("Text withheld pending review.</b>") && src.indexOf("Text withheld pending review.</b>") < src.indexOf("De-listed by moderation.</b>"));
ok("banner keeps the lifecycle sentence", src.includes("the lifecycle is unaffected"));
ok("seeded span keeps the realm sentence + punctuation", src.includes("seeded by a moderator to start this court; the author earns nothing from it"));
ok("D6-critic: seeded read fails CLOSED", src.includes(') !== false; // unread = never offer the draw'));
ok("D6-critic: hidden claims get no map link", src.includes("mHidden!==true && (!isLive()"));
ok("D6-critic: demo raw claims carry the chain banner", src.includes("**Hidden by this court's moderators.**"));
ok("D6-critic: demo raw court links its mod log", src.includes("[Moderation log](/r/kourt/kourtv2:${parts[0]}/mod)"));
ok("D6-critic: demo totals count the whole court", src.includes("demoCourt(slug)? demoCourt(slug).claims.length"));
ok("banner reads are claim-route only, null-safe", src.includes("mHidden=null, mRedacted=null, mPurged=null, mSeeded=null"));
ok("me rider: seeded read guards the author row", src.includes("d.seeded = (await one(`ClaimSeeded(") );
ok("tour: moderation specimens section", src.includes("<h2>Moderation specimens</h2>") && src.includes('href="#/c/annex/${i}"'));
ok("annex/1 is a complete open claim", DEMO.claims["annex/1"] && DEMO.claims["annex/1"].phase==="open" && statusText(DEMO.claims["annex/1"]).length>0);
ok("every demo claim names its opener", Object.values(DEMO.claims).every(d=>d.author));
// demo mirrors the render's omission
ok("demo listCourts filters tier 0", src.includes('filter(([,c])=>c.tier!==0) // the render omits hidden courts'));
ok("demoRender lists only tier 1 under Courts", src.includes('if(c.tier===1) o+=`- [${c.name}]'));
ok("hidden demo count = 1", Object.values(DEMO.courts).filter(c=>c.tier===0).length===1);

// strip + disclosure strings
ok("strip: three tiles", src.includes('>courts listed<') && src.includes('>featured<') && src.includes('>claims filed<'));
ok("strip: no money summed", !/total GNOT|GNOT burned across|summed supply/.test(src));
ok("hidden count never renders slugs", src.includes("COUNT only — the slugs never enter the DOM"));
ok("completeness certificate", src.includes("no courts are hidden by moderation — this register is complete."));
ok("hidden-count failure copy", src.includes("whether courts are hidden is unknown right now"));
ok("unlisted court line", src.includes("unlisted — hidden from the directory by moderation; this page is reachable by direct link only."));
ok("docket short-window note (hedged per critic F1)", src.includes("hidden or unreadable claim") && src.includes("a hidden claim's page still answers by id."));

// opened-by + answer record
ok("opened-by reads once, claim route only", (src.match(/ClaimAuthor\(/g)||[]).length===3);
// "opened by" is prose and sets in the sans; the address is a machine string
// and is the only mono in the row. The whole span used to be mono, which is
// why it read as a fourth typeface in a six-item row.
// The elision is for the eye only: shortAddr() cuts the middle out and the full
// address appears nowhere else on this route, so a screen reader was handed an
// address that cannot be used. Both halves are pinned — the short one hidden
// from the accessible name, the whole one in it.
ok("opened-by chip via shortAddr",
   src.includes('<span class="mono" aria-hidden="true">${shortAddr(author)}</span>'));
ok("and the whole address reaches a screen reader",
   src.includes('<span class="sr-only">${esc(author)}</span>'));
ok("answer record nonzero-only", src.includes('${arec>0?` · answer record ${fmtN(arec)} — contested-and-upheld`:""}'));
ok("answer record footnote", src.includes("an overturn resets it to zero"));
ok("rail gnoweb exit is live-only", src.includes('id="gwrealm"') && src.includes('gw.style.display = live? "inline-block":"none"'));

// §7.4 sweep of the new copy
{
  const seg = slice('/* The docket\'s impersonal clock','function pctYes') + slice('const statsStrip','const card') ;
  ok("§7.4 clean in D5 copy", !/backing|redeem\b|profit|APR|worth|winnings|wager/i.test(seg));
}
ok("applySort keeps a focused row focused", src.includes("hadFocus.focus({preventScroll:true})"));
ok("D6-1: raw route accepts /mod", src.includes("(?:\\/(\\d+|mod))?"));
ok("D6-1: demo mod-log sample keeps the charter", src.includes("it never moves a coin or changes a verdict"));
ok("D6-1: sample rows are realm-shaped", src.includes("approved, expires at height") && src.includes("· by g1modalpha"));
ok("D6-critic: per-court stories (annex narrates its hides)", src.includes("global-hide:code-2026-041"));
ok("D6-1: log linked from court, curate + 3 banners", (src.match(/raw\/\$\{esc\(slug\)\}\/mod/g)||[]).length===5);
ok("D5-critic F1: window note hedges unreadable", src.includes("hidden or unreadable claim") && !src.includes("de-listed by moderation in this window"));
ok("D5-critic F3: fills die with their render", (src.match(/renderSeq!==seq0\) return;/g)||[]).length>=3);
console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
