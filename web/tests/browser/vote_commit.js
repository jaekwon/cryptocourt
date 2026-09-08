// The vote-commitment line tells a voter what their vote would commit.
//
// THE BUG THIS STANDS OVER, and it shipped because the formatter was tested and
// the WIRING was not. fillVoteCommitment read w[1] from ClaimVoteWeightOf —
// the QUALITY weight — and voteLockFigures only emits "this vote would commit
// N" when that figure is above zero. Nothing assigns quality any more, so the
// second return is always 0, so the sentence never rendered: for anybody, on
// any claim, on the live site. The one number a voter wants before voting was
// silently absent, and the comment at the call site asserted the opposite —
// "nothing on the page would look wrong if this read the other one".
//
// votelock_test.js covers voteLockFigures thoroughly, including that a zero is
// omitted rather than printed as 0. It cannot catch this: its source slice ends
// at `async function fillVoteCommitment(`, so the formatter is pinned and the
// argument handed to it is not. A pure function tested in isolation says
// nothing about the value its only caller passes.
//
// SO THIS CHECKS THE WIRING, in a browser, by answering the chain read with a
// verdict weight and a zero quality weight — the shape the realm actually
// returns today — and requiring the rendered sentence to carry the verdict
// figure. Reverting the index to w[1] makes the sentence disappear, which is
// the failure the arm is for.
//
// window.fetch is the stub seam: the overlay's read helpers are all `const`,
// and puppeteer request interception never sees a cross-origin fetch from a
// file:// page (measured zero posts). Everything above fetch is real — the
// envelope decode, parseTyped's tuple split, the formatter, the DOM write.
//
// THE PANEL IS A FIXTURE, and it has to be. #votecommit lives inside the
// dispute explainer's "What casting costs you" section, which renders only
// while a verdict vote is open — and no claim in the sample carries an open
// dispute, so neither demo nor a stubbed live page produces the element. The
// span is created here and fillVoteCommitment is called directly on it, which
// is the function under test; where the span sits on the page is not. This is
// the same reason verdict_notice.js renders its own panel.
//
// ABLATED against a CONTROL run of the unmodified page, which fires nothing:
//   - index back to w[1]                -> 1: the sentence arm. The panel goes
//     empty, which is exactly what a reader saw before this was fixed.
//   - swap the stub's two values, so quality carries the figure and verdict is
//     0 -> 1: the same arm, confirming it reads position 0 and not "whichever
//     number happens to be non-zero".
// Mutations run against a COPY outside the repo: a second session edits this
// file, and an in-place mutation has been written back from a stale buffer once.
const {PAGE, demoPage} = require('./harness');

// 12 CC verdict weight, 0 quality — the shape ClaimVoteWeightOf returns now.
const VERDICT = 12000000;

(async () => {
  const {browser, page, errs} = await demoPage({width: 1280, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  const read = async (verdict, quality) => {
    // A fresh load per case: same-URL navigation is same-document, so the page
    // would not rebuild and the second case would measure the first.
    await page.goto(PAGE + `?vc=${verdict}-${quality}#/c/orem/1`, {waitUntil: 'domcontentloaded'});
    await new Promise(r => setTimeout(r, 900));
    return page.evaluate(async (v, q) => {
      // The RPC cache lives in sessionStorage and survives a reload, so a
      // second case would be served the first one's answer.
      for (let i = sessionStorage.length - 1; i >= 0; i--) {
        const k = sessionStorage.key(i);
        if (k && k.indexOf("rpcc") === 0) sessionStorage.removeItem(k);
      }
      CFG.mode = "live";
      CFG.rpc = "http://stub.invalid/";
      CFG.addr = "g1votecommitfixture000000000000000000";
      const realFetch = window.fetch;
      const asked = [];
      window.fetch = async (url, opts) => {
        let expr = "";
        try { expr = atob(JSON.parse(opts.body).params.data); } catch (e) {}
        asked.push(expr.split("\n").pop());
        // A tuple comes back as one line per value, which is what parseTyped
        // splits on — so the stub has to answer in that shape, not as one line.
        const val = /ClaimVoteWeightOf/.test(expr) ? `(${v} int64)\n(${q} int64)`
          : /VoteLockedOf/.test(expr)   ? '(0 int64)'
          : /DisposableOf/.test(expr)   ? '(50000000 int64)'
          : /VoteWeightWhy/.test(expr)  ? '("because" string)\n("gone" string)'
          : '("" string)';
        return {ok: true, status: 200, json: async () => ({
          jsonrpc: "2.0", id: "cc",
          result: {response: {ResponseBase: {Data: btoa(val)}}}})};
      };
      try {
        const host = document.createElement("span");
        host.id = "votecommit";
        document.getElementById("main").appendChild(host);
        await fillVoteCommitment("orem", 1);
        return {text: (host.textContent || "").replace(/\s+/g, " ").trim(),
                askedWeight: asked.some(e => e.indexOf("ClaimVoteWeightOf") >= 0)};
      } finally { window.fetch = realFetch; CFG.mode = "demo"; delete CFG.addr; }
    }, verdict, quality);
  };

  const live = await read(VERDICT, 0);
  ok("the claim page reads the voter's weight", live.askedWeight === true,
     JSON.stringify(live).slice(0, 160));
  // THE ARM. 12000000 micro is 12.00 of the court's coin.
  ok("...and says what the vote would commit, from the VERDICT weight",
     /this vote would commit 12/.test(live.text), live.text || "<empty>");
  // The panel also carries the other two figures, so a regression that empties
  // the whole thing is distinguishable from one that drops only this sentence.
  ok("...alongside what is free to bond",
     /free to bond/.test(live.text), live.text || "<empty>");

  ok("no page errors", errs.length === 0, errs.slice(0, 2).join(" | "));

  await browser.close();
  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
