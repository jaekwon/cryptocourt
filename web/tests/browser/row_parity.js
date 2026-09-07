// A CLAIM'S ROW IS THE SAME ROW ON THE COURT PAGE AND ON A SET PAGE.
//
// docketRow builds it for both, so they SHOULD be identical — and for a long
// time they were not, in ways nothing here noticed:
//
//   the stake figure  the court page filled `[data-pct]` from a sweep written
//                     inline in its own route; a set page drew the same cell and
//                     ran nothing, so every claim under every set showed an
//                     empty signal. Claim #10 read "82.4%" on one page and
//                     nothing on the other. Fixed by extracting fillDocketRows.
//   the clock         same cell, same story: `#clk-<slug>-<id>` never filled.
//   the fold keys     no keys passed meant `data-fold="~none"`, which does not
//                     mean "no filter here" — it means the claim is in NO
//                     folder, and every claim on a set page is in at least one.
//
// Each of those was found by hand, by fetching one row from both pages and
// diffing the strings. This is that diff, standing.
//
// THE ONE LEGITIMATE DIFFERENCE IS THE FOLDER META, and it is asserted rather
// than ignored. The court page names the first folder a claim is in, because
// there the folder is news. A set page names the SUBSET a claim came from, and
// says nothing at all for a claim filed in the set itself — repeating the name
// of the page you are on is not information. So: everything else identical, and
// the meta different in exactly that way.
//
// WHY A BROWSER. Both rows are built by one function, so a source test can only
// confirm that both callers exist; whether the two pages AGREE is a property of
// the settled DOM.
//
// AND WHAT THIS CANNOT SEE, said plainly because it is the bug above. In demo
// mode the stake figure comes from docketRow itself — a demo claim carries its
// own pools, so both pages print "71.0%" with no fill running anywhere — and
// removing the set page's fillDocketRows call leaves this check green. MEASURED,
// by doing exactly that. The fill only matters against a live chain, which this
// harness has no access to.
// So the fill is covered where it can be: folders_test asserts that
// fillDocketRows is defined ONCE and called by BOTH routes, which is the thing
// that went wrong — a sweep living in one route. What this file adds is
// everything demo CAN show: the shell of the row, the fold keys, the clock cell,
// and the one difference that is meant to be there.
const {PAGE, demoPage} = require('./harness');

(async () => {
  const {browser, page, errs} = await demoPage({width: 1440, height: 1000});
  let fail = 0;
  const ok = (m, c, d) => { if (!c) { fail++; console.log("FAIL: " + m + (d ? "  " + d : "")); } else console.log("ok: " + m); };

  // The row for one claim, taken off whichever page is loaded. `.m` spans are
  // separated from the rest: the folder meta is the span WITHOUT an id, the
  // clock is the one with `id="clk-…"`, and only the first is allowed to differ.
  const rowOf = (id) => page.evaluate((id) => {
    const r = [...document.querySelectorAll(".main .crow.claimrow")]
      .find(x => (x.getAttribute("href") || "").endsWith("/" + id));
    if (!r) return null;
    const clone = r.cloneNode(true);
    const metas = [...clone.querySelectorAll("span.m")];
    const folder = metas.filter(m => !m.id).map(m => m.textContent.trim());
    const clocks = metas.filter(m => /^clk-/.test(m.id || ""));
    folder.forEach((_, i) => metas.filter(m => !m.id)[i].remove());
    return {
      // the row with its folder meta taken out — everything else must match
      shell: clone.outerHTML.replace(/\s+/g, " ").trim(),
      folder: folder.join(" | ") || null,
      hasClock: clocks.length,
      // what the reader actually sees in the signal cell
      signal: (r.querySelector(".sig[data-pct]") || {}).textContent?.trim() || "",
      yes: r.dataset.yes || null,
      fold: r.getAttribute("data-fold"),
    };
  }, id);

  // A claim filed directly in a set, so the set page has a folder page for it
  // AND the court page lists it under that folder's name.
  await page.goto(PAGE + "#/c/orem/f/0", {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1200));
  const id = await page.evaluate(() => {
    const r = document.querySelector(".main .crow.claimrow");
    return r ? Number((r.getAttribute("href") || "").split("/").pop()) : null;
  });
  ok("a set page in the demo lists a claim to compare", Number.isFinite(id) && id > 0, String(id));
  if (!Number.isFinite(id)) { console.log("\n1 FAILURES"); await browser.close(); process.exit(1); }

  const set = await rowOf(id);
  await page.goto(PAGE + "#/c/orem", {waitUntil: 'networkidle0'});
  await new Promise(z => setTimeout(z, 1200));
  const court = await rowOf(id);

  ok(`#${id} has a row on both pages`, !!(set && court),
     JSON.stringify({set: !!set, court: !!court}));
  if (!set || !court) { console.log(`\n${fail + 1} FAILURES`); await browser.close(); process.exit(1); }

  /* THE WHOLE ROW, minus the folder meta. This is the assertion the three bugs
     above would each have failed: a missing signal, a missing clock and a
     `~none` where keys belong all live inside this string. */
  ok(`#${id}: the row is identical on both pages once the folder meta is set aside`,
     set.shell === court.shell,
     set.shell === court.shell ? "" : "\n    set:   " + set.shell + "\n    court: " + court.shell);

  ok(`#${id}: ...including the stake figure a reader sees`,
     set.signal === court.signal && set.yes === court.yes,
     JSON.stringify({set: [set.signal, set.yes], court: [court.signal, court.yes]}));

  ok(`#${id}: ...and the folders it says it is in`,
     set.fold === court.fold && set.fold !== "~none",
     JSON.stringify({set: set.fold, court: court.fold}));

  ok(`#${id}: ...and both carry the clock cell`,
     set.hasClock === court.hasClock && court.hasClock === 1,
     JSON.stringify({set: set.hasClock, court: court.hasClock}));

  /* AND THE META DIFFERS IN THE ONE WAY IT SHOULD. The claim is filed directly
     in this set, so the set page says nothing — you are on that set's page — and
     the court page names the folder, where it is news. */
  ok(`#${id}: the court page names the folder and the set page does not`,
     !set.folder && !!court.folder,
     JSON.stringify({set: set.folder, court: court.folder}));

  ok("no page errors on either route", errs.length === 0, errs.slice(0, 2).join(" | "));

  console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
