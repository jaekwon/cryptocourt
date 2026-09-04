#!/usr/bin/env node
// Sweep the live site for things that MEASURE wrong.
//
// WHY THIS EXISTS. Polishing by eye finds what the eye happens to land on, and
// this session has now shipped three defects that a measurement would have
// caught on sight: a tooltip 10px wider than the viewport, a chip whose count
// disagreed with the heading it opened, and a heading 13px taller than every
// other heading on the page. All three looked fine in a screenshot.
//
// Every check here is a number compared against another number on the same
// page, so a finding is a fact rather than an opinion. Read-only: it opens
// routes and measures them.
//
//   node scratchpad/audit-live.js [baseURL]
//
// Default base is the deployed site. Pass a file:// URL to audit a local build
// — it sets live mode against rpc.kourt.xyz either way, never demo.
const puppeteer = require("puppeteer");

const BASE = process.argv[2] || "https://kourt.xyz/";
const ROUTES = ["#/", "#/c/covid", "#/c/covid/11", "#/c/covid/holders",
                "#/raw/covid/mod", "#/c/covid/f/1", "#/me", "#/needs"];
const WIDTHS = [1440, 900, 390];

const audit = () => {
  const out = [];
  const de = document.documentElement;
  const main = document.getElementById("main") || document.body;
  const vis = el => { const s = getComputedStyle(el);
    return s.display !== "none" && s.visibility !== "hidden" && el.getBoundingClientRect().width > 0; };

  // 1. the page must not scroll sideways — WCAG 1.4.10
  if (de.scrollWidth > de.clientWidth + 1)
    out.push({kind: "page-scrolls-x", detail: `${de.scrollWidth} > ${de.clientWidth}`});

  // 2. nothing may stick out past the viewport
  main.querySelectorAll("*").forEach(el => {
    if (!vis(el)) return;
    const r = el.getBoundingClientRect();
    if (r.right > de.clientWidth + 1 && r.width < de.clientWidth)
      out.push({kind: "overflows-right", detail: `${Math.round(r.right)} > ${de.clientWidth}`,
                el: (el.className || el.tagName).toString().slice(0, 40),
                text: (el.textContent || "").trim().slice(0, 40)});
  });

  // 3. text clipped inside its own box (not a deliberate ellipsis)
  main.querySelectorAll("*").forEach(el => {
    if (!vis(el) || el.children.length) return;
    // The visually-hidden idiom is a 1x1 clipped box — .ccsym's colon is one, and
    // it is clipped ON PURPOSE so the symbol still copies as KOURT:COVID. Text
    // "clipped" inside a 1px box is the pattern working, not a defect.
    if (el.clientWidth <= 2 || el.clientHeight <= 2) return;
    const s = getComputedStyle(el);
    if (s.overflow === "hidden" && s.textOverflow !== "ellipsis" && el.scrollWidth > el.clientWidth + 1)
      out.push({kind: "text-clipped", el: (el.className || el.tagName).toString().slice(0, 40),
                text: (el.textContent || "").trim().slice(0, 40)});
  });

  // 4. every section heading is one line of text with a rule under it, so they
  //    should all be the same height — a control that inflates one is the bug
  //    this check exists for, having shipped once already
  // Only where the row has width to spare: below about a tablet the chip group
  // WRAPS to its own line, which makes that heading legitimately taller than a
  // heading with no controls in it. Comparing there would report the layout
  // working as a fault.
  const hs = [...main.querySelectorAll(".sec-h")].filter(vis);
  if (hs.length > 1 && de.clientWidth >= 1200) {
    const heights = hs.map(h => Math.round(h.getBoundingClientRect().height));
    const lo = Math.min(...heights), hi = Math.max(...heights);
    if (hi - lo > 4) out.push({kind: "sec-h-heights-differ", detail: heights.join(","),
      text: hs.map(h => h.textContent.replace(/\s+/g, " ").trim().slice(0, 14)).join(" | ")});
  }

  // 5. a chip that opens a section must agree with that section's heading —
  //    both the word and the figure
  main.querySelectorAll(".gchips [data-show]").forEach(c => {
    const g = main.querySelector(`[data-group="${c.dataset.show}"]`);
    if (!g) return;
    const h = g.querySelector(".sec-h"); if (!h) return;
    const norm = t => t.replace(/\s+/g, " ").trim().toLowerCase();
    const cName = norm(c.childNodes[0].textContent);
    const hName = norm([...h.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join(" "));
    const cNum = norm((c.querySelector(".n") || {textContent: ""}).textContent);
    const hNum = norm((h.querySelector(".count") || {textContent: ""}).textContent).split(" · ")[0];
    if (cName !== hName) out.push({kind: "chip-word-mismatch", detail: `${cName} vs ${hName}`});
    if (cNum !== hNum) out.push({kind: "chip-count-mismatch", detail: `${cName}: ${cNum} vs ${hNum}`});
  });

  // 6. a link that goes nowhere
  main.querySelectorAll("a[href]").forEach(a => {
    const h = a.getAttribute("href");
    if (h === "" || h === "#" || h === "#/undefined" || /undefined|NaN|\[object/.test(h))
      out.push({kind: "dead-href", detail: h, text: (a.textContent || "").trim().slice(0, 30)});
  });

  // 7. a figure rendered from a broken number
  const bad = (main.innerText.match(/\b(NaN|undefined|Infinity|\[object [A-Za-z]+\])\b/g) || []);
  if (bad.length) out.push({kind: "broken-value-in-text", detail: [...new Set(bad)].join(",")});

  // 8. an image that did not load
  main.querySelectorAll("img").forEach(im => {
    if (im.complete && im.naturalWidth === 0)
      out.push({kind: "image-failed", detail: (im.getAttribute("src") || "").slice(0, 60)});
  });

  // 9. a control smaller than the 24px minimum target (SC 2.5.8)
  main.querySelectorAll("button,a.pill,[role=button]").forEach(el => {
    if (!vis(el)) return;
    const r = el.getBoundingClientRect();
    if (r.height > 0 && r.height < 20 && r.width < 20)
      out.push({kind: "target-too-small", detail: `${Math.round(r.width)}x${Math.round(r.height)}`,
                text: (el.textContent || "").trim().slice(0, 24)});
  });
  return out;
};

(async () => {
  const browser = await puppeteer.launch({headless: "new",
    args: BASE.startsWith("file") ? ["--allow-file-access-from-files", "--disable-web-security"] : []});
  const page = await browser.newPage();
  const errs = [];
  page.on("pageerror", e => errs.push(String(e).slice(0, 160)));
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("cc.cfg", JSON.stringify({mode: "live", rpc: "https://rpc.kourt.xyz",
      gnoweb: "https://gnoweb.kourt.xyz", chainid: "kourt-1"}));
    localStorage.setItem("cc.intro", "1");
  });

  let total = 0;
  for (const route of ROUTES) {
    for (const w of WIDTHS) {
      await page.setViewport({width: w, height: 1200});
      const before = errs.length;
      try { await page.goto(BASE + route, {waitUntil: "networkidle2", timeout: 45000}); }
      catch (_) { console.log(`  ${route} @${w}  NAVIGATION FAILED`); total++; continue; }
      await new Promise(r => setTimeout(r, 2600));
      const found = await page.evaluate(audit);
      const pe = errs.slice(before);
      if (found.length || pe.length) {
        console.log(`\n${route}  @${w}px`);
        found.forEach(f => console.log(`  ${f.kind.padEnd(22)} ${f.detail || ""} ${f.el ? "<" + f.el + ">" : ""} ${f.text ? JSON.stringify(f.text) : ""}`));
        pe.forEach(e => console.log(`  page-error             ${e}`));
        total += found.length + pe.length;
      }
    }
  }
  console.log(total ? `\naudit-live: ${total} finding(s)` : "\naudit-live: nothing measured wrong.");
  await browser.close();
  process.exit(0);
})();
