#!/usr/bin/env node
// THE COMPOSER — who may write, why not, and what gets signed.
//
// Every branch of composerState is a different person being turned away for a
// different reason, and getting one wrong tells somebody a false thing about
// their own account. Two of the branches exist only because posting.gno does
// something non-obvious, and those two are the point of this file:
//
//   PassPrice == 0 has TWO causes — an unsealed court and a zero-supply one —
//   and only PostLevel separates them.
//
//   PostsAvailable == 0 does NOT mean "out for today". It returns 0 for an
//   address with no standing row at all, and in a zero-supply court that same
//   address is level 3, so the naive reading tells a first-time visitor they
//   have used posts they never had.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'index.html'), 'utf8');
const { slice } = require("./srcslice");
const V = s => s.replace(/^const /gm, 'var ');
eval(slice('function esc(s){', '\n/* undo the realm'));
eval(slice('function fmtN(', '\n'));
eval(slice('function cc(n, slug){', '\nfunction ugnot('));
eval(slice('function ccSym(', '\n'));
eval(V(slice('const shq =', '\n\n')));
eval(slice('const GAS_WANTED', 'const CFG_DEFAULTS') + slice('function cliCmd(', '\n\n'));
// MAX_COMMENT_CHARS is read out of the file, never restated: it is pinned to the
// realm's maxBoardTextLen by check-web-constants, and a copy here would be a
// third place for it to drift.
const MAX_COMMENT_CHARS = parseInt(src.match(/^const MAX_COMMENT_CHARS = (\d+);/m)[1], 10);
var CFG = {mode:"live", chainid:"kourt-1", rpc:"https://rpc.example.test"};
var PKG = "gno.land/r/kourt/kourtv2";
eval(V(slice('function composerState(', '\n/* ---- the reads behind it ---- */')));

let fail=0; const ok=(n,c)=>{ if(!c){fail++; console.log("FAIL:",n);} else console.log("ok:",n); };
const st = o => Object.assign({addr:"g1me", now:1000, boardOpen:true, claimFrozenUntil:0,
  frozenUntil:0, level:1, posts:3, perDay:5, passPrice:0, supply:1}, o);

// ---- the cap is the realm's ----------------------------------------------
{
  ok("the character cap is declared, and this file reads it rather than restating it",
     MAX_COMMENT_CHARS === 2000);
}

// ---- the gates, most specific first ---------------------------------------
{
  // A closed board beats every other reason: there is nothing to say about
  // allowances on a board nobody can write to.
  const closed = composerState(st({boardOpen:false, addr:null, level:0}));
  ok("a closed board is the first thing said", !closed.can && /verdict/.test(closed.why));
  ok("...and it does not also ask for a wallet", !closed.connect);

  const frozenBoard = composerState(st({claimFrozenUntil:2000, addr:null}));
  ok("a paused board is named before a missing wallet",
     !frozenBoard.can && frozenBoard.why.includes("block 2,000") && !frozenBoard.connect);
  ok("...and an EXPIRED pause is not a pause",
     composerState(st({claimFrozenUntil:999})).can === true);

  const noWallet = composerState(st({addr:null}));
  ok("no wallet asks for one", !noWallet.can && noWallet.connect === true);

  const frozenMe = composerState(st({frozenUntil:2000}));
  ok("a paused ADDRESS is told about itself, not the board",
     !frozenMe.can && /Your posting/.test(frozenMe.why) && frozenMe.why.includes("block 2,000"));
  // BOTH pauses need the expired case, not just the board's: they are separate
  // comparisons and an ablation that froze the address permanently survived
  // until this line existed.
  ok("...and an expired address pause is not a pause",
     composerState(st({frozenUntil:999})).can === true);
}

// ---- PassPrice == 0 has two causes ---------------------------------------
{
  const buyable = composerState(st({level:0, passPrice:12_000_000}));
  ok("no standing, with a price to quote, offers the pass",
     !buyable.can && buyable.buy === 12_000_000);

  // The SAME level and the SAME price, different cause. An unsealed court has no
  // price yet; offering a Buy here sends somebody at a call that panics.
  const unsealed = composerState(st({level:0, passPrice:0}));
  ok("no standing and no price says why, and offers no pass",
     !unsealed.can && !unsealed.buy && /has not sealed an epoch/.test(unsealed.why));
  ok("...and the two zero-price states do not read the same",
     unsealed.why !== buyable.why);
}

// ---- PostsAvailable == 0 is not "out for today" ---------------------------
{
  const spent = composerState(st({posts:0, perDay:5, supply:118_500_000_000}));
  ok("a real court with an allowance spent says so",
     !spent.can && spent.why === "You have used today's 5 comments.");
  ok("...singular at one", composerState(st({posts:0, perDay:1, supply:1})).why
     === "You have used today's 1 comment.");

  // THE MISFIRE. Zero supply makes postLevel return 3 to everyone while
  // PostsAvailable returns 0 for an address that has never posted. Telling that
  // person they had used five comments would be false about their own account.
  const fresh = composerState(st({level:3, posts:0, perDay:5, supply:0}));
  ok("a zero-supply court does not claim posts were used", !/used today/.test(fresh.why));
  ok("...and does not block the attempt the realm would allow", fresh.can === true);
  ok("...saying instead that the allowance is not readable here",
     /cannot be read here/.test(fresh.why) && /decides when you sign/.test(fresh.why));

  const fine = composerState(st({posts:3}));
  ok("an address with posts left is told how many", fine.can && fine.why === "You can post 3 more comments today.");
  ok("...singular at one", composerState(st({posts:1})).why === "You can post 1 more comment today.");
}

// ---- the shell command a reader pastes ------------------------------------
// A comment body is now one of these arguments. `--args "` + value + `"` was
// fine while every argument was a slug or an id.
{
  ok("an ordinary value is quoted", shq("covid") === "'covid'");
  // The one character single quoting cannot contain, handled the only way it
  // can be: close, escape, reopen.
  ok("an apostrophe is closed, escaped and reopened",
     shq("it's") === "'it'\\''s'");
  ok("a double quote needs nothing inside single quotes", shq('say "no"') === `'say "no"'`);
  ok("a newline survives literally", shq("a\nb") === "'a\nb'");
  ok("a dollar sign is not expanded", shq("$HOME `id`") === "'$HOME `id`'");

  const cmd = cliCmd("PostComment", {courtSlug:"covid", claimID:"3", parentRow:"0",
                                     text:`it's "4|3" & $PATH`}, "");
  ok("the command quotes every argument", !cmd.includes('--args "'));
  ok("...and the body's apostrophe does not end the argument",
     cmd.includes(`--args 'it'\\''s "4|3" & $PATH'`));
  // The shape a reader depends on, unchanged by the quoting fix.
  ok("...while the command is still a gnokey maketx call",
     cmd.startsWith("gnokey maketx call") && cmd.includes("--broadcast"));
}

// ---- the wiring -----------------------------------------------------------
// The signing exception is exactly one button wide, and the button has to be the
// one that carries it.
{
  // THE EXCEPTION SURVIVED ITS OWN GENERALISATION. Every button confirms in a
  // dialog now, not just this one — but the composer's body still gets the
  // treatment the others do not: shown whole, read-only, and passed through
  // UNTRIMMED, because signing something other than what was displayed is the
  // failure this path exists to prevent.
  ok("the sign path still knows an authored body from a prefilled argument",
     src.includes('el.dataset.authored ? (el.dataset.bodykey || "text") : null'));
  // THE INTENT, stated directly. This was a proximity regex — no `func ===`
  // within 80 characters of `dataset.authored` — and it now trips on the NEXT
  // argument, where `func==="Buy"` legitimately selects the spend field. What
  // must not happen is the authored body being chosen by function name.
  ok("...gated on the dataset flag, not on the function name",
     !/bodyKey\s*=\s*func\s*===/.test(src)
     && !/func\s*===\s*"PostComment"/.test(src));
  ok("...and the body is the one field the dialog does not trim",
     /if\(k === bodyKey\) return String\(args\[k\]\);\s*\/\/ untrimmed/.test(src));
  ok("...while every other field is trimmed", src.includes("inp.value.trim()"));
  ok("...and shown read-only, with its length against the chain's cap",
     /if\(k === bodyKey\)\{[\s\S]{0,300}<pre class="cliblock mono">/.test(src)
     && src.includes("of ${fmtN(MAX_COMMENT_CHARS)} characters"));
  ok("the composer's post button is the one marked authored",
     src.includes('class="btn composer-post" data-authored="1"'));
  // NO NATIVE PROMPTS LEFT ANYWHERE. A loop of window.prompt() asked one box per
  // argument — three to cast a vote — and Chrome suppresses repeated prompt()
  // calls, returning null with nothing drawn, which surfaced as "Cancelled —
  // nothing was signed" for a cancellation nobody made. A <dialog> cannot be
  // suppressed.
  ok("the confirmation is a real dialog, and the only one",
     src.includes("function confirmArgs(") && src.includes("dlg.showModal()")
     && !src.includes("confirmAuthored"));
  // CODE, not prose. The comment above confirmArgs names window.prompt() in
  // order to say why it is gone; a file-wide ban would ban the explanation —
  // the same trap votelock_test hit with SpendableOf.
  ok("...with no window.prompt CALL left anywhere",
     !src.split("\n").some(l => /window\.prompt\(/.test(l)
        && !/^\s*(\/\/|\*|\/\*)/.test(l)));
  // Buy's spend was a FOURTH prompt after the others had been answered. It is a
  // field in the same dialog now, and a bad amount is refused in place rather
  // than ending the signature and sending the reader back to the button.
  // THE DIALOG IS THE EXCEPTION NOW, not the rule. Every button used to stop and
  // ask; nothing was earned by it, because the arguments on a claim page are
  // derived by the page and Adena's own approval popup shows the call before
  // anything is signed. What survives is the case it was built for: an argument
  // the reader must REPLACE.
  ok("a derived-argument button signs straight through",
     /\} else \{\s*\n\s*vals = Object\.keys\(args\|\|\{\}\)\.map\(k => String\(args\[k\]\)\);/.test(src));
  ok("...and the dialog is reached only by the three that need it",
     src.includes("if(el.dataset.edit || el.dataset.authored || needsSend){"));
  // The two buttons that ship literal placeholders. Signing these through would
  // create a court called "My Court".
  // COUNTED ON btn( CALLS, not on the argument shape alone. ",false,true)" is a
  // positional tail any function can end with, and one did — a fourth-and-fifth
  // argument on an unrelated call made this read "three placeholder buttons".
  ok("the placeholder buttons are marked, and they are the only ones",
     (src.match(/btn\([^\n]*,false,true\)/g)||[]).length === 2
     && /StartCourt",\{slug:"my-court",name:"My Court"\},"primary",null,null,false,true\)/.test(src)
     && src.includes('data-edit="1"'));
  // A concrete amount comes from the receipt input the reader typed into; the
  // no-quote fallback ships the literal "AMOUNTugnot", a placeholder like any
  // other, and that one still has to be asked for.
  ok("a real spend is taken as typed, a placeholder one is asked for",
     src.includes('const sendOk = /^[1-9][0-9]*ugnot$/.test(sendRaw);')
     && src.includes('const needsSend = func === "Buy" && !sendOk;')
     && src.includes("This is burned. Treat it as spent."));
  ok("...and a bad amount is refused without closing it",
     /e\.hidden = false; e\.textContent = "A whole, non-zero ugnot amount\.";\s*\n\s*return;/.test(src));
  // BOTH call sites, named separately. Asserting `includes("fillComposer(")`
  // once is satisfied by either, so deleting the list-page call passed while the
  // composer had vanished from every board that has comments.
  ok("the composer is filled on a board with comments",
     src.includes("if(!ranked) fillComposer(slug, id, 0);"));
  ok("...and on an empty one, where it matters most",
     /<div id="composer"><\/div>`;\s*\n\s*fillComposer\(slug, id, 0\);/.test(src));
  ok("...but not on the ranked view, which would be a second place to lose a draft",
     src.includes('(ranked ? "" : `<div id="composer"></div>`)'));
  // CODE POINTS, matching the realm's runeLen. String.length is UTF-16 code
  // units, so an emoji counts twice there and once in Gno.
  ok("the counter measures code points, matching the realm",
     src.includes("[...String(s == null ? \"\" : s)].length"));
}

console.log(fail? "\n"+fail+" FAILURES" : "\nALL PASS");
process.exit(fail?1:0);
