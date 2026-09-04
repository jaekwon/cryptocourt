#!/usr/bin/env node
// Does the site tell the same story twice?
//
// WHY THIS EXISTS. audit-live measures one page against itself — geometry,
// naming, reachability. It cannot see the other half of what goes wrong here,
// which is two SURFACES describing one fact and describing it differently: a
// chip that said "settled" over a heading that said "recently settled", a coin
// amount written "CC" beside tiles wearing the gold mark, a %YES on a docket row
// that is a different number from the same claim's own page.
//
// Every check reads one fact from two places and compares. A finding is two
// quoted strings that ought to be one.
//
//   node scratchpad/audit-agree.js [baseURL]
const puppeteer = require("puppeteer");
const BASE = process.argv[2] || "https://kourt.xyz/";
const COURT = "covid";

let bad = 0;
const cmp = (what, a, b, note) => {
  const same = String(a) === String(b);
  if (!same) { bad++; console.log(`  DISAGREE  ${what}\n              directory/court: ${JSON.stringify(a)}\n              other surface:   ${JSON.stringify(b)}${note ? "\n              " + note : ""}`); }
  else console.log(`  agree     ${what}  ${JSON.stringify(a)}`);
};

(async () => {
  const browser = await puppeteer.launch({headless: "new",
    args: BASE.startsWith("file") ? ["--allow-file-access-from-files", "--disable-web-security"] : []});
  const page = await browser.newPage();
  await page.setViewport({width: 1440, height: 1400});
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "live", rpc: "https://rpc.kourt.xyz",
      gnoweb: "https://gnoweb.kourt.xyz", chainid: "kourt-1"}));
    localStorage.setItem("cc.intro", "1");
  });
  const go = async (r, ms = 3600) => { await page.goto(BASE + r, {waitUntil: "networkidle2", timeout: 45000});
    await new Promise(x => setTimeout(x, ms)); };
  const norm = t => String(t == null ? "" : t).replace(/\s+/g, " ").trim();

  // ---- the directory's row for this court vs the court's own page ----------
  console.log("\ndirectory row  vs  court page");
  await go("#/");
  const dir = await page.evaluate(slug => {
    const row = [...document.querySelectorAll(".docket a.courtrow")]
      .find(a => (a.getAttribute("href") || "").endsWith("/c/" + slug));
    if (!row) return null;
    const txt = row.innerText.replace(/\s+/g, " ").trim();
    return {name: (row.querySelector(".t") || {}).textContent || "",
            claims: (txt.match(/(\d[\d,]*)\s+claims?/) || [])[1] || null,
            // The row shows PRICE and SUPPLY, not the burn — an earlier version
            // of this check compared a figure the directory never prints and
            // reported the court page for having one.
            supply: (txt.match(/·\s*([\d,]+)\s*Kourt/) || [])[1] || null, txt};
  }, COURT);
  await go("#/c/" + COURT);
  const court = await page.evaluate(() => {
    const tile = lab => {
      const t = [...document.querySelectorAll(".courtstats .stat")]
        .find(x => new RegExp(lab, "i").test(x.textContent));
      return t ? t.innerText.replace(/\s+/g, " ").trim() : "";
    };
    const rec = [...document.querySelectorAll(".panel")].find(p => /court record/i.test(p.textContent));
    return {h1: (document.querySelector("h1.page-h") || {}).textContent || "",
            supply: (tile("coin supply").match(/([\d,]+)\s*Kourt/) || [])[1] || null,
            claims: rec ? (rec.innerText.match(/of this court's ([\d,]+) claims/) || [])[1] || null : null,
            showAll: (document.querySelector('.gchips [data-show="all"] .n') || {}).textContent || null};
  });
  if (!dir) console.log("  (no directory row for this court — skipped)");
  else {
    cmp("the court's name", norm(dir.name), norm(court.h1));
    cmp("coin supply", dir.supply, court.supply);
    cmp("how many claims it has", dir.claims, court.claims,
        "directory row vs the court's own Court record panel");
  }

  // ---- a claim on the docket vs its own page ------------------------------
  await go("#/c/" + COURT);
  const rows = await page.evaluate(() => [...document.querySelectorAll(".docket a.crow.claimrow")]
    .slice(0, 4).map(r => ({
      id: (r.querySelector(".id") || {}).textContent.replace("#", "").trim(),
      title: (r.querySelector(".t") || {}).textContent.replace(/\s+/g, " ").trim(),
      pct: ((r.querySelector(".px") || {}).textContent.match(/([\d.]+)%/) || [])[1] || null,
      side: (r.querySelector(".vtag") || {}).textContent || null,
      contested: !!r.querySelector(".vqm,.sq"),
    })));
  for (const r of rows) {
    console.log(`\ndocket row #${r.id}  vs  its claim page`);
    await go(`#/c/${COURT}/${r.id}`);
    const cl = await page.evaluate(() => {
      const h = document.querySelector("h1.page-h");
      const bar = document.querySelector(".sbout");
      return {title: h ? h.textContent.replace(/\s+/g, " ").trim() : "",
              side: (h && h.querySelector(".vtag") || {}).textContent || null,
              contested: !!(h && h.querySelector(".sq,.vqm")),
              pct: bar ? ((bar.innerText.match(/YES\s*([\d.]+)%/) || [])[1] || null) : null};
    });
    // the row's title carries the oval's text; compare the sentence only
    const rowTitle = r.title.replace(/\s*(YES|NO)\s*\??\s*$/, "").trim();
    const pageTitle = cl.title.replace(/\s*(YES|NO)\s*\??\s*$/, "").trim();
    cmp(`#${r.id} title`, rowTitle, pageTitle);
    cmp(`#${r.id} answered side`, norm(r.side), norm(cl.side));
    cmp(`#${r.id} shown as contested`, r.contested, cl.contested);
    cmp(`#${r.id} %YES`, r.pct, cl.pct);
  }

  // ---- a folder's count on the court page vs the folder's own page --------
  await go("#/c/" + COURT);
  const folders = await page.evaluate(() => [...document.querySelectorAll(".docket a.folderrow")]
    .slice(0, 3).map(f => ({href: f.getAttribute("href"),
      name: (f.querySelector(".t") || f).textContent.replace(/\s+/g, " ").trim().split(/\d/)[0].trim(),
      count: ((f.querySelector(".px") || {}).textContent.match(/(\d+)/) || [])[1] || null})));
  for (const f of folders) {
    console.log(`\nfolder "${f.name}" on the court page  vs  its own page`);
    await go(f.href.replace(/^#/, "#"));
    const fp = await page.evaluate(() => {
      const sec = [...document.querySelectorAll(".sec-h")].find(h => /^Claims/i.test(h.textContent));
      // The heading says the TOTAL when it differs from what is filed directly
      // — "0 filed here · 9 with its subfolders" — and a bare number when the
      // two are the same. The row's figure is the total either way, so that is
      // what this compares.
      const t = sec ? sec.textContent.replace(/\s+/g, " ") : "";
      const total = (t.match(/([\d,]+) with its subfolders/) || [])[1]
        || (t.match(/(\d[\d,]*)/) || [])[1] || null;
      return {count: total && total.replace(/,/g, ""),
              h1: (document.querySelector("h1.page-h") || {}).textContent.replace(/\s+/g, " ").trim()};
    });
    cmp(`"${f.name}" claim count`, f.count, fp.count,
        "the court page's folder row vs the folder page's own Claims heading");
  }

  console.log(bad ? `\naudit-agree: ${bad} disagreement(s)` : "\naudit-agree: every surface tells the same story.");
  await browser.close();
  process.exit(0);
})();
