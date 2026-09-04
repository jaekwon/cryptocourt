// D5 harness: clockLine table, the annex exemplar, demo mirrors, strip strings,
// opened-by, answer record, §7.4 sweep.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
const { slice } = require("./srcslice");
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
/* THE DISPUTED ROW HAS A CLOCK NOW. The old note said reading DisputeVoteCloses
   would be a query per row on a page that draws fifty — but the docket's fill
   already pays exactly that for `proposed` and `provisional`, and only for the
   rows in those phases. Disputed was the last one sending a reader elsewhere for
   a number the row could hold.
   THE TALLY IS STILL SEALED, which is the realm's design: the ballots are on
   chain and anyone may add them up, but this page does not sum a running vote.
   So the line says WHEN, never who is winning — asserted below. */
ok("disputed with no close read yet = the bare sealed line",
   clockLine(null,"in dispute",null,null)==="a sealed vote is deciding"
   && clockLine(123,"in dispute",99,99)==="a sealed vote is deciding");
ok("...with a close and a height, it counts down",
   // wall() spells the duration in words — "about 2 hours 38 min" — so the tail is
   // matched as prose rather than as one token, which is what this first got wrong.
   /^the vote closes in about \S.*$/.test(clockLine(100,"in dispute",null,null,2000)));
ok("...past the close, it says the verdict is available",
   clockLine(3000,"in dispute",null,null,2000)==="the vote has closed — the verdict is one call away");
/* A BLOCK NUMBER IS NOT AN ANSWER TO "WHEN". These lines carried both — "in 2.6d
   — ≈block 244,800" — and the height is the machinery under the answer rather
   than the answer. It stays in exactly one place: where there is no chain height
   to measure against, so no duration can be computed and the block is the only
   true thing left. */
ok("a duration never carries a block number beside it", (()=>{
  const withHeight = [clockLine(100,"in dispute",null,null,2000),
                      clockLine(100,"proposed",200,null),
                      clockLine(100,"provisional",null,150)];
  return withHeight.every(t => !/block/.test(t));
})());
ok("...and the block survives where there is no height to measure from", (()=>{
  return /≈block/.test(clockLine(null,"in dispute",null,null,2000))
      && /≈block/.test(clockLine(null,"proposed",200,null))
      && /≈block/.test(clockLine(null,"provisional",null,150));
})());
ok("...and with no height to measure against, it states the block alone",
   clockLine(null,"in dispute",null,null,2000)==="the vote closes at ≈block 2,000");
ok("...and never reports a tally, which is sealed while it runs", (()=>{
   const all = [clockLine(100,"in dispute",null,null,2000),
                clockLine(3000,"in dispute",null,null,2000),
                clockLine(null,"in dispute",null,null,null)].join(" ");
   return !/%|YES|NO|winning|ahead/.test(all);
})());
/* AND THE DOCKET ACTUALLY FETCHES IT. clockLine renders a countdown only if it
   is handed a close, so the phase has to be in the fill that reads one — the
   same fill that already reads SettleDeadline and EscrowUntil for the other two
   phases, and only for the rows in them. Source-asserted: the fill needs a chain.
   Removing the phase from that condition left every clockLine test passing and
   no row counting down. */
ok("the docket reads the close for a disputed row",
   src.includes('|| pcShort==="in dispute"')
   && src.includes('`DisputeVoteCloses(${s2},${cl.id})`')
   && src.includes('pcShort==="in dispute"? h:null'));
ok("...and no surface still claims the chain publishes no close height",
   !src.includes("no close height is published"));
ok("proposed ahead", /^settles undisputed in about .+ unless disputed$/.test(clockLine(100,"proposed",200,null)));
ok("proposed past", clockLine(300,"proposed",200,null)==="the settle window has passed — anyone may settle it now");
ok("proposed, no height read", clockLine(null,"proposed",200,null)==="settles undisputed at ≈block 200");
ok("provisional ahead", /^reopenable for about .+$/.test(clockLine(100,"provisional",null,150)));
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
/* FOUR CALL SITES, AND THE CLAIM ROUTE STILL READS IT ONCE. The fourth is
   claimParties' fallback, which exists because the participant guard on "Open
   the rewards" needs the author and cannot trust that its caller supplied one —
   the route used to read it into a LOCAL and never put it on `d`, so the guard
   bailed silently and a reader met the panic in their wallet instead. The route
   sets d.author now, which is what keeps the fallback from ever firing there:
   that assignment is asserted below, and it is the thing that makes "reads
   once" still true. */
/* A FIFTH CALLER, and it needs the author for the same reason the fourth does.
   refreshClaimRewards re-renders the ticket after a reward write without going
   through the route, so it has to put d.author on the record itself — the pulls
   are pruned by claimParties, and an absent author makes the participant guard
   bail exactly as it did when the route kept the author in a local. */
ok("opened-by has one read per caller that needs it",
   (src.match(/ClaimAuthor\(/g)||[]).length===5);
ok("...and the partial refresh is one of them, for the participant guard",
   /refreshClaimRewards[\s\S]{0,900}ClaimAuthor\(/.test(src));
ok("...and the claim route puts it on d, so the fallback never fires there",
   src.includes("if(author) d.author = author;"));
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
