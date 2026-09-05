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

  // ---- the overlay vs THE CHAIN'S OWN WORDS -------------------------------
  // The strongest comparison available: /raw is the realm's own render, the
  // markdown a gnoweb visitor sees. Anywhere the friendly page and that page
  // disagree, the overlay is the one that is wrong — it is a reading of the
  // chain, and the chain is right by construction.
  console.log("\ncourt page  vs  the chain's own render");
  await go("#/raw/" + COURT);
  const raw = await page.evaluate(() => {
    const src = (document.getElementById("rawsrc") || {}).textContent || "";
    return {claims: (src.match(/^-\s.*?—\s*(\d[\d,]*)\s*claims?/im) || [])[1] || null,
            heading: (src.match(/^#\s+(.+)$/m) || [])[1] || null,
            price: (src.match(/price:\s*([\d,]+)\s*ugnot/i) || [])[1] || null,
            supply: (src.match(/in circulation:\s*([\d,]+)/i) || [])[1] || null,
            reservoir: (src.match(/reward reservoir:\s*([\d,]+)/i) || [])[1] || null};
  });
  // sanitize.InlineText backslash-escapes markdown punctuation, so the chain's
  // heading reads "COVID\-19 Origins \& Response Court" — the same name, spelled
  // for a markdown renderer. Compare the letters.
  const unesc = t => norm(t).replace(/\\(.)/g, "$1");
  cmp("the court's name, against the chain's heading", unesc(court.h1), unesc(raw.heading));
  // The chain counts in base units and the page in CC — 1e6 to one — so the
  // figures differ by construction and comparing them raw reported the page for
  // doing its job. Compared after the conversion the page performs.
  if (raw.supply) {
    const chainCC = Math.round(Number(raw.supply.replace(/,/g, "")) / 1e6);
    cmp("coin supply, against the chain (base units → CC)",
        Number((court.supply || "0").replace(/,/g, "")), chainCC);
  }

  for (const r of rows.slice(0, 2)) {
    console.log(`\nclaim #${r.id}  vs  the chain's own render of it`);
    await go(`#/raw/${COURT}/${r.id}`);
    const rc = await page.evaluate(() => {
      const src = (document.getElementById("rawsrc") || {}).textContent || "";
      return {title: (src.match(/^#\s+(.+)$/m) || [])[1] || null,
              says: /disputed|dispute/i.test(src) ? "disputed"
                  : /provisional/i.test(src) ? "provisional"
                  : /settled/i.test(src) ? "settled" : "open"};
    });
    // the chain escapes markdown punctuation; compare the letters, not the slashes
    const strip = t => norm(t).replace(/\\(.)/g, "$1");
    cmp(`#${r.id} title, against the chain`, strip(r.title.replace(/\s*(YES|NO)\s*\??[\s\S]*$/, "")), strip(rc.title));
    cmp(`#${r.id} is contested, against the chain`, r.contested, rc.says === "disputed");
  }

  // ---- the map's card vs the claim's own page -----------------------------
  console.log("\nthe map's card  vs  the claim page");
  const first = rows[0];
  await go(`#/c/${COURT}/map?focus=${first.id}`, 5200);
  const card = await page.evaluate(() => {
    const t = document.querySelector(".mapsel-t");
    return {title: t ? t.textContent.replace(/\s+/g, " ").trim() : null,
            side: (t && t.querySelector(".vtag") || {}).textContent || null};
  });
  if (!card.title) console.log("  (the map did not open a card for it — skipped)");
  else {
    cmp(`#${first.id} title on the map`, norm(first.title.replace(/\s*(YES|NO)\s*\??[\s\S]*$/, "")),
        norm(card.title.replace(/\s*(YES|NO)\s*\??[\s\S]*$/, "")));
    cmp(`#${first.id} side on the map`, norm(first.side), norm(card.side));
  }

  console.log(bad ? `\naudit-agree: ${bad} disagreement(s)` : "\naudit-agree: every surface tells the same story.");
  await browser.close();
  process.exit(0);
})();
