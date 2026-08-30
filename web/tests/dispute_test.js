// B4 harness: disputeTicket from the live file, demo + live shapes.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');
function slice(from, to){
  const a = src.indexOf(from); if(a<0) throw new Error("missing "+from);
  const b = src.indexOf(to, a); if(b<0) throw new Error("missing "+to);
  return src.slice(a, b);
}
global.document = { addEventListener: ()=>{}, getElementById: ()=>null };
global.CFG = { mode:'demo', gnoweb:'https://gno.land', rpc:'http://x', chainid:'dev' };
global.PKG = 'gno.land/r/kourt/kourtv2';
global.isLive = ()=> CFG.mode==='live';
const NOWm = src.match(/const NOW\s*=\s*([0-9_]+)/); global.NOW = NOWm? Number(NOWm[1].replace(/_/g,'')) : 4800000;
const BSm = src.match(/const BLOCK_SECS\s*=\s*([0-9_]+)/); global.BLOCK_SECS = BSm? Number(BSm[1].replace(/_/g,'')) : 5;

let code = '';
code += slice('function esc(', '\n');
code += slice('function fmtN(', 'function ugnot(');
code += slice('const sideName', '\n');
code += slice('function shortAddr(', '\n');
code += slice('function wall(', 'function pctYes');
code += 'var NOW='+global.NOW+';\n';
// Round 28 split the literal: DEMO_CHAIN (generated) + DEMO_OVERLAY
// (hand-written: desc, nested folders, relations, voteEndsAt), joined by
// mergeDemo. Build the merged object the way the page does.
code += slice('const DEMO_OVERLAY = {', '/* ===== BEGIN GENERATED').replace('const DEMO_OVERLAY = {','var DEMO_OVERLAY = {') + '\n';
code += slice('const DEMO_CHAIN = {', '/* ===== END GENERATED').replace('const DEMO_CHAIN = {','var DEMO_CHAIN = {') + '\n';
code += slice('function mergeDemo(', 'const DEMO = mergeDemo') + '\n';
code += 'var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n';
code += slice('function tx(func', 'document.addEventListener("click"');
code += slice('const MON=', 'function resolutionLadder(');
// This slice carries ballotHint too — it sits between the modal and the ticket.
code += slice('function voteHelpModal(', 'function disputeTicket');
code += slice('function disputeTicket', 'async function fillVoteEligibility');
eval(code);

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };

const d = Object.assign({}, DEMO.claims["orem/3"]);
const html = disputeTicket("orem", 3, d, NOW);

// THE BALLOT IS THE QUESTION, ONE LINE OF CLOCK, AND THE BUTTONS. Quorum, the
// threshold, the locking rule, what each outcome does to whose bond and the
// token flows were seven dense lines between the question and the buttons — a
// reader had to get through the mechanism to reach the choice. All of it is in
// the modal now.
ok("ballot h3", html.includes("Should this answer be overturned?"));
ok("the hint is one line, and it is the clock",
   html.includes('<div class="hint">Closes in about'));
// THE ROUND WENT TO THE TIMELINE, where the claim's other events are. The
// ballot must not keep a second copy of it — on ANY branch. Asserted against
// the rendered fixture alone, this passed while the no-close-height branch
// still said "Round 2": the fixture has a voteEndsAt and never reaches it.
ok("...with no round number on it, on any branch",
   !/<div class="hint">[^<]*[Rr]ound \d/.test(html)
   && [ballotHint("orem", d, NOW),
       ballotHint("orem", Object.assign({}, d, {voteEndsAt:null}), NOW),
       ballotHint("orem", d, null),
       ballotHint("orem", Object.assign({}, d, {voteEndsAt:NOW-1}), NOW)]
        .every(x => !/[Rr]ound \d/.test(x)));
// "One vote per address, and you cannot change it" is a rule about a mistake:
// it means something only to somebody who has already cast the vote it would
// undo. It is said at click time now, from a read, to the address it applies to.
ok("...and no standing warning about changing a vote",
   !html.includes("One vote per address"));
// A hint that runs onto a third sentence about mechanism is the thing this
// replaced, so the SHAPE is asserted, not just the content — and against every
// branch, because the longest one is not the branch the fixture happens to take.
{
  const h = html.match(/<div class="hint">([^<]*)</)[1];
  const all = [h,
    ballotHint("orem", Object.assign({}, d, {voteEndsAt:null}), NOW),
    ballotHint("orem", d, null),
    ballotHint("orem", Object.assign({}, d, {voteEndsAt:NOW-1}), NOW)];
  ok("...and every branch of it is one short sentence",
     all.every(x => x.length < 60 && !x.includes("\n")
                    && x.trim().split(/\.\s+/).length === 1));
}
// The passed-window branch drops the voting rule instead of appending it: it is
// noise to somebody who can no longer vote, and joining it on made the sentence
// read "Round 3 — voting has closed — Resolve works now".
ok("a closed window says only that, and says it without a second dash",
   ballotHint("orem", Object.assign({}, d, {voteEndsAt:NOW-1}), NOW)
     === "Voting has closed; Resolve works now.");
ok("no outcome rows: what overturning does to whose bond is modal copy",
   !html.includes("the answer stays YES") && !html.includes("the answer becomes NO"));
ok("no vote-lock row on the ballot either",
   !html.includes("<span>voting locks</span>") && !html.includes('id="votecommit"'));
// The round HISTORY is gone from the page entirely — the notice above the ballot
// already says "(after 2 failed rounds)", which is the same fact in fewer words.
ok("the spent-round ladder is gone from the file",
   !src.includes("failed quorum — half that round's disputer bond burned")
   && !src.includes("disputeRounds"));
// DisputeBondNext quotes what the NEXT DISPUTE costs (dispute.gno:849). The row
// that carried it said "voting now at 64.0 KOURT:OREM", which tells a voter they
// must pay to vote. Voting costs no bond, so the figure is not carried forward.
ok("...and no bond figure sits beside the word voting",
   !html.includes("voting now at") && !/voting[^.]*KOURT:OREM/.test(html));
// The eligibility paragraph left the ballot entirely: the reason only matters to
// the reader it applies to, and only when they reach for the button.
ok("eligibility is not a standing paragraph", !html.includes("holder can vote"));
ok("...the vote buttons are marked for the click-time check",
   html.includes('id="voteactions"'));
ok("...and Resolve sits outside that block, being no vote at all",
   html.indexOf("Resolve (after close)") > html.indexOf('id="voteactions"')
   && html.split('id="voteactions"')[1].indexOf("</div>") < html.split('id="voteactions"')[1].indexOf("Resolve"));
// The DATED close is the resolution ladder's row — it always had one, and the
// ballot was printing a second copy of it as a labelled row. The hint's clock is
// a phrase inside a sentence, not a second ladder.
// The ROW, not the words: the modal legitimately says "until the vote closes",
// and an assertion that cannot tell prose from a duplicated row is one that
// fails for the wrong reason.
ok("clock: no second copy of the close row on the ballot",
   !html.includes("<span>vote closes</span>"));
// THE 7-DAY LINE IS GONE. It was the WINDOW'S LENGTH, not the time left in it,
// so a claim three days into its round read the same as one three minutes in.
// DisputeVoteCloses publishes the close height now and the client reads it, so
// this branch means the read failed — and it says so instead of substituting a
// number that looks like an answer.
ok("clock: a failed read says so rather than guessing a window",
   ballotHint("orem", Object.assign({}, d, {voteEndsAt:null}), NOW)
     === "The closing time could not be read.");
// WHAT RENDERS, not what the file says. A file-wide ban also bans the comment
// that explains why the line went — the same trap votelock_test hit with
// SpendableOf, where the guard has to be "nothing CALLS it", not "the string
// never appears". Every branch is checked, since only one of them carried it.
ok("...and no branch of the hint substitutes a window length for a countdown",
   [ballotHint("orem", d, NOW),
    ballotHint("orem", Object.assign({}, d, {voteEndsAt:null}), NOW),
    ballotHint("orem", d, null),
    ballotHint("orem", Object.assign({}, d, {voteEndsAt:NOW-1}), NOW)]
     .every(x => !/7 days|a week/.test(x)));
// nowH null is a DIFFERENT branch from voteEndsAt absent: the height IS known and
// merely unprojectable. It must print that height rather than the 7-day guess,
// which would be an invented date printed over a fact the chain gave.
ok("clock: a known height with no clock to project it prints the height",
   ballotHint("orem", d, null).includes("Closes at block "));
// Quorum LEFT the ballot. The rule and the figure are in the modal, where a
// reader who wants the mechanism can find both — and the ballot no longer
// spends a row on arithmetic nobody is being asked to do.
ok("quorum is off the ballot", !html.includes("<span>required quorum</span>"));
ok("...and in the modal, rule first then figure",
   html.includes("If too little weight is cast, the round decides nothing at all")
   && html.includes("5,925 KOURT:OREM"));
ok("no bare jargon label left", !html.includes("turnout bar"));
ok("threshold is off the ballot", !html.includes("<span>threshold</span>"));
ok("...and stated in the modal in plain words",
   html.includes("more than half the weight voted has to say overturn")
   && html.includes("A tie upholds"));
ok("sealed = un-summed not secret", html.includes("Sealed means un-summed, not secret"));
// The modal heading asserted the same false thing the ballot sentence did, in
// the second person. Removing one and keeping the other would have left the
// help page telling a reader they cannot do what the paragraph under it
// explains how to do.
ok("the modal explains what the PAGE does, not what the reader cannot",
   html.includes("Why this page does not add them up")
   && !html.includes("Why you cannot see the count"));
ok("...and says where the count can be had instead",
   html.includes("can read it off the chain"));
ok("no 'secret ballot'", !/secret ballot/i.test(html));
// Said ONCE now, in the modal. The ballot says who may vote; how the weight is
// measured is mechanism.
ok("weight is the pre-round snapshot, said in the modal",
   html.includes("whatever you held at the last hourly snapshot before this round opened"));
// The demo-exclusion note went with the eligibility paragraph. In demo mode
// every action button is already inert and says "Demo data — actions work on a
// live node", which is the truer message than a note about staking.
ok("no eligibility prose survives on the ballot",
   !html.includes("cannot vote") && !html.includes("holder can vote"));
ok("abstain button with turnout-only sub", html.includes("> Abstain") && html.includes("counts to turnout only, never to a side"));

// ---- one control per action, and it is the one with the verb on it --------
// It used to be three: a gnoweb link carrying the label, a "CLI" toggle, and —
// only when a wallet happened to be connected already — a small "✍ Sign". So
// the page's primary action was a link OFF the page, and a reader with no
// wallet saw nothing that said signing was even possible.
{
  // A LIVE BALLOT. `html` above is the demo render, where every button is inert
  // by design — asserting the action markup against it passes for the wrong
  // reason or not at all. The first version of this block did the latter.
  const save = CFG.mode; CFG.mode = "live";
  const L = disputeTicket("orem", 3, d, NOW);
  CFG.mode = save;

  const one = L.match(/<span class="act">[\s\S]*?<\/span>/g) || [];
  ok("each action is a single control", one.length >= 3
     && one.every(a => (a.match(/<button|<a /g)||[]).length === 1));
  ok("...and it is a button, not a link off the page",
     !/<span class="act"><a /.test(L) && !L.includes('target="_blank"'));
  ok("no CLI toggle rides along any more",
     !L.includes(">CLI<") && !L.includes("clitog") && !html.includes("clitog"));
  ok("no separate sign button either", !L.includes("signbtn") && !html.includes("signbtn"));
  // Everything the two removed controls carried still travels, on the button,
  // for the dialog to use.
  ok("the button carries what it needs to sign, to link and to quote",
     /data-act="1"/.test(L) && /data-func="VoteDispute"/.test(L)
     && /data-args="/.test(L) && /data-cli="/.test(L) && /data-tx="/.test(L));
  // Demo keeps its own guarantee: inert, and carrying no runnable command for
  // sample arguments.
  ok("...and demo stays inert, with nothing runnable on it",
     html.includes('data-inert="1"') && !html.includes("data-cli") && !html.includes("data-act"));
}
// DECIDED AT CLICK TIME. Whether a wallet is connected can change while the
// panel is on screen, so a control that committed to gnoweb at render would be
// wrong by the time it was pressed. Both conditions are required: CFG.addr is
// remembered in storage and outlives the extension that produced it.
ok("the handler asks the wallet at the moment of the click",
   src.includes("if(CFG.addr && window.adena) adenaSign(act.dataset.func, args, act);")
   && src.includes("else signHelp(act);"));
// The three refusals must come FIRST — each is a reason the click must not
// become a transaction.
ok("...after the refusals, not before them",
   src.indexOf('closest("[data-inert]")') < src.indexOf('closest("[data-act]")')
   && src.indexOf('closest("[data-voteblocked]")') < src.indexOf('closest("[data-act]")')
   && src.indexOf('closest("[data-needack]")') < src.indexOf('closest("[data-act]")'));
// ---- the dialog is a flow, not a dead end ---------------------------------
ok("no wallet connected opens help rather than a silent new tab",
   /function signHelp\(el\)/.test(src));
ok("...offering Connect when the extension is there",
   src.includes("data-connect") && src.includes("Connect Adena"));
ok("...and the interrupted action retries itself once connected",
   /await adenaConnect\(\);[\s\S]{0,300}if\(CFG\.addr\) el\.click\(\);/.test(src));
// A failed connect must not reopen the same dialog forever.
ok("...but only if the connect actually took", src.includes("if(CFG.addr) el.click();"));
ok("...names the file:// trap, where no extension can ever load",
   src.includes("extensions do not run on") && src.includes("file://"));
ok("...and keeps both key-holding fallbacks, gnoweb and the command line",
   src.includes("Open in gnoweb") && src.includes("cliBlock(cli)"));
ok("the copy fallback survives a page with no clipboard API",
   /function cliBlock\(cmd\)/.test(src) && src.includes("no-clipboard")
   && src.includes("Selected — press Ctrl/⌘-C"));
ok("abstain arg choice=abstain", html.includes('"choice":"abstain"') || html.includes("abstain"));
// The rule is stated ONCE now, in the modal — it was on the ballot and in the
// modal, in two different sets of words for the same fact.
ok("who-pays-whom: burn/mint rule, in plain words",
   html.includes("Nothing moves from one side to the other.")
   && html.includes("no pot to win")
   && html.includes("Coin that is forfeited is burned"));
ok("quorum-fail: the answer bond survives, third round closes",
   html.includes("half the challenger's bond burns, half comes back")
   && html.includes("The answerer's bond is untouched")
   && html.includes("After a third failed round the claim closes undecided"));
ok("overturn make-good capped, both limits",
   html.includes("never more than twice their bond, never more than 80% of what burned"));
ok("no live-tally leak words", !/has voted|votes so far|current tally|leading/i.test(html));
ok("no banned words", !/backing|redeem\b|profit|APR|share if right/i.test(html));

// claim WITHOUT demo position (ledger/1 hypothetical dispute) — no sample-exclusion line
const d2 = Object.assign({}, DEMO.claims["orem/3"]);
const html2 = disputeTicket("ledger", 1, d2, NOW);
ok("no exclusion teaching when sample holds no position", !html2.includes("sample address holds a stake"));

// live shape: no voteEndsAt/quorumFloor → honest absence lines
CFG.mode='live';
const dl = Object.assign({}, DEMO.claims["orem/3"]); delete dl.voteEndsAt; delete dl.quorumFloor;
const htmlL = disputeTicket("orem", 3, dl, 5000000);
ok("live: no invented deadline",
   htmlL.includes("The closing time could not be read."));
// The read that made the guess unnecessary. Asserted as the CALL, because a
// realm function nobody invokes is the failure this feature would otherwise
// have: the ballot would look identical and always take the read-failed path.
ok("live: the close height is read from the chain",
   src.includes('DisputeVoteCloses(${s},${i})')
   && /disputeOpen\) d\.voteEndsAt = await one/.test(src));
ok("live: no turnout row without read", !htmlL.includes("turnout bar"));
// The async fill marks the vote BUTTONS now instead of writing a paragraph, so
// what has to be present is the block it looks for.
ok("live: the vote buttons are findable by the async check",
   htmlL.includes('id="voteactions"'));
CFG.mode='demo';

// past-close demo: Resolve-works copy
const d3 = Object.assign({}, DEMO.claims["orem/3"], {voteEndsAt: NOW-100});
const html3 = disputeTicket("orem", 3, d3, NOW);
ok("past close: resolve works now",
   html3.includes("Voting has closed; Resolve works now"));
// ...and it replaces the countdown rather than sitting beside it. A ballot that
// says both "closes in 2 days" and "voting has closed" is worse than either.
ok("...instead of a countdown, not beside one", !/Closes in/.test(html3));


// ---- B4 critic fixes ----
ok("uphold: bond held to finalise + the same payment limits",
   html.includes("The answerer's bond stays held until the claim is finished")
   && html.includes("the same kind of payment on the same limits"));
// F4 WAS A TRUTHFULNESS FIX ON COPY THAT NO LONGER EXISTS. The outcome rows
// asserted "whoever challenged it loses their bond" and "the answerer loses
// their bond", both false once the answer bond had already burned in an earlier
// overturned round — so the rows grew a zero-bond branch. The rows are gone, and
// with them the claim: the fix is now structural rather than conditional. What
// has to hold is that the ballot says NOTHING about anybody's bond at either
// value, so there is no untruth left to special-case.
const d0 = Object.assign({}, DEMO.claims["orem/3"], {answerBond:0});
const html0 = disputeTicket("orem", 3, d0, NOW);
const ballotOf = h => h.slice(0, h.indexOf("<dialog"));   // the modal may discuss bonds; the ballot may not
ok("F4: the ballot claims nothing about a bond at zero", !/bond/i.test(ballotOf(html0)));
ok("F4: ...nor at 80 KOURT:OREM, so the two read alike", !/bond/i.test(ballotOf(html)));
ok("F4: and the two ballots differ in nothing at all",
   ballotOf(html0) === ballotOf(html));
const srcF = fs.readFileSync(require('path').join(__dirname,'..','index.html'),'utf8');

// THE WIRING, as text, because there is no DOM here. Both of these were absent
// and both ablations survived: the rounds block rendered correctly and was
// never placed on the page, and the click gate could be deleted with every
// assertion still green. A renderer with no caller is the failure this feature
// has had more than once.
ok("the ballot actually calls the hint it renders",
   srcF.includes("${ballotHint(slug, d, nowH)}"));
ok("the click gate turns the mark into a sentence",
   srcF.includes('closest("[data-voteblocked]")')
   && /vb\)\{ ev\.preventDefault\(\)/.test(srcF)
   && srcF.includes('getAttribute("data-voteblocked")'));
ok("F1: voteEndsAt in chart domain candidates", /const cands=\[now, d\.settleAt\|\|null, d\.escrowUntil\|\|null, d\.voteEndsAt\|\|null, ansH\]/.test(srcF));
// The HEDGE is the point — that a clean-looking eligibility read is not the
// final word — not which noun carries it. Matched as a pattern so renaming
// "realm" to "court" for readers does not read as a lost guarantee.
// THE HEDGE MOVED WITH THE CHECK. It used to reassure an eligible reader in a
// standing paragraph; now the check runs at click time and says nothing at all
// unless it has a reason, so there is no affirmative left to hedge. What still
// has to be true is that the page never promises the vote will be accepted —
// the court decides at signing — so the copy states what it SAW, not what will
// happen.
ok("F3: the click-time reason states what was seen, not what will happen",
   /You cannot vote on this claim: you /.test(srcF)
   && !/your vote will be (accepted|refused)/i.test(srcF));
// ALREADY VOTED — the rule that left the ballot has to land somewhere, and this
// is where. Read from CommitmentsOf rather than remembered client-side: a
// verdict-lane row exists only while the round that made it is open, which is
// exactly the window in which "you cannot change it" is true.
ok("F5: the click-time check reads whether this address already voted",
   srcF.includes('CommitmentsOf(${gstr(slug)},${gstr(CFG.addr)})')
   && /r\.kind==="d" && r\.id===Number\(id\)/.test(srcF));
ok("F5: ...and says the rule that used to sit on every ballot",
   /have already voted in this round, and a vote cannot be changed/.test(srcF));
// "You cannot vote on this claim: you have already voted" would be wrong — they
// could, and did. The sentence has to switch stems, not just its tail.
ok("F5: ...without telling them they cannot do what they just did",
   srcF.includes('(voted? "You " : "You cannot vote on this claim: you ")'));

// ticket rows: label bold on the LEFT, value left-aligned in its own column,
// with a real gutter (owner report: bold-right, ragged-left, columns touching)
ok("ticket rows are a two-track grid with a gutter", src.includes(".ticket .line,.qrows .line{display:grid; grid-template-columns:minmax(0,20ch) minmax(0,1fr); column-gap:24px"));
ok("the label is the bold thing", src.includes(".ticket .line>*:first-child,.qrows .line>*:first-child{font-weight:600; color:var(--ink)}"));
ok("values read left-to-right, not right-adjusted", src.includes(".ticket .line .r,.qrows .line .r{font-weight:400; color:var(--ink-2); text-align:left"));
ok("no space-between left in the rule", !src.includes(".ticket .line{display:flex; justify-content:space-between"));
ok("narrow screens stack the pair", src.includes("@media (max-width:640px){ .ticket .line,.qrows .line{grid-template-columns:minmax(0,1fr)"));
// the helper modal: the long "why" lives one click away, keyboard-reachable
ok("modal: one dialog, native, labelled", html.includes('<dialog class="helper" id="help-vote" aria-labelledby="help-vote-h">'));
ok("modal: triggers are BUTTONS (an href-less <a> cannot be tabbed to)", html.includes('<button type="button" class="helplink" data-help="help-vote">') && !html.includes('<a class="helplink"'));
// The ballot keeps ONE line of prose and one link. The burn/mint rule used to
// sit here as well as in the modal, in two different sets of words.
// "NOBODY CAN SEE THE COUNT UNTIL VOTING CLOSES" IS GONE, and not for brevity:
// it is false. Every vote is a public transaction and anyone can total them —
// what is true is that this page will not. The modal has always said so
// ("Sealed means un-summed, not secret"), so the ballot was contradicting its
// own help link one line above it.
ok("the ballot makes no claim about what a reader can see",
   !/can see the count|cannot see the count|[Nn]obody can see/.test(html));
// The link moved up beside the clock, which is the only other thing left on the
// ballot between the question and the buttons.
ok("the help link rides the hint, not a paragraph of its own",
   /<div class="hint">[^<]*<button type="button" class="helplink" data-help="help-vote">How this vote works →<\/button><\/div>/.test(html));
ok("...and no orphan paragraph is left where it used to sit",
   !/<p class="small muted"[^>]*>\s*<button type="button" class="helplink"/.test(html));
ok("...and no longer restates the token rule on the ballot",
   !html.includes("forfeits are burned, awards are newly minted"));
ok("the dense blocks are gone from the ticket body", !html.includes("a running count would make copying the first big voter") && !html.includes("there is no pot to steer"));
ok("plain-English rewrite present",
   html.includes("the best move would be to wait and copy whoever voted with the most weight"));
ok("§7.4 holds in the new copy", !/backing|redeem|APR|profit|return on/i.test(html) && html.includes("staked KOURT:OREM is never touched"));
ok("the token is named, not \"money\"", html.includes("KOURT:OREM") && !/\bmoney\b/.test(html));
ok("canonical display is KOURT:SLUG", html.includes("Anyone holding KOURT:OREM"));
ok("the word \"money\" appears nowhere in the file", (()=>{ const fs=require("fs");
  return !/\bmoney\b/i.test(fs.readFileSync(require('path').join(__dirname,'..','index.html'),"utf8")); })());
console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
