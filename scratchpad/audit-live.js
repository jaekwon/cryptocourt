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
    // A FAILED image is one that was ASKED FOR and did not arrive. An <img> with
    // no src attribute is an empty slot waiting to be filled — the share
    // preview is one, drawn on a canvas when its dialog opens — and reporting it
    // as a failure is reporting the absence of a request. The page hides those
    // so they never paint as broken; what matters here is a src that 404'd.
    const src = im.getAttribute("src");
    if (src && im.complete && im.naturalWidth === 0)
      out.push({kind: "image-failed", detail: src.slice(0, 60)});
  });

  // 9. a control smaller than the 24px minimum target (SC 2.5.8)
  main.querySelectorAll("button,a.pill,[role=button]").forEach(el => {
    if (!vis(el)) return;
    const r = el.getBoundingClientRect();
    if (r.height > 0 && r.height < 20 && r.width < 20)
      out.push({kind: "target-too-small", detail: `${Math.round(r.width)}x${Math.round(r.height)}`,
                text: (el.textContent || "").trim().slice(0, 24)});
  });
  // ---- second wave: things that are wrong without being misplaced ----------

  // 10. contrast (WCAG 1.4.3). The effective background is the nearest ancestor
  //     that paints one; text over an image or a gradient is skipped rather than
  //     guessed at.
  const lum = c => { const [r, g, b] = c.map(v => { v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const rgb = str => { const m = String(str).match(/rgba?\(([^)]+)\)/);
    if (!m) return null; const p2 = m[1].split(",").map(parseFloat);
    return p2.length > 3 && p2[3] < 0.95 ? null : [p2[0], p2[1], p2[2]]; };
  const bgOf = el => { for (let n = el; n && n !== document.documentElement; n = n.parentElement) {
      const s2 = getComputedStyle(n);
      if (s2.backgroundImage && s2.backgroundImage !== "none") return null;
      const c = rgb(s2.backgroundColor); if (c) return c; }
    return rgb(getComputedStyle(document.body).backgroundColor); };
  const seenC = new Set();
  main.querySelectorAll("*").forEach(el => {
    if (!vis(el) || el.children.length) return;
    const t = (el.textContent || "").trim(); if (t.length < 2) return;
    const s2 = getComputedStyle(el);
    const fg = rgb(s2.color), bg = bgOf(el); if (!fg || !bg) return;
    const L1 = lum(fg), L2 = lum(bg);
    const ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
    const px = parseFloat(s2.fontSize), bold = parseInt(s2.fontWeight, 10) >= 700;
    const large = px >= 24 || (px >= 18.66 && bold);
    const need = large ? 3 : 4.5;
    if (ratio < need) {
      const key = s2.color + "|" + ratio.toFixed(2);
      if (seenC.has(key)) return; seenC.add(key);
      out.push({kind: "contrast-low", detail: `${ratio.toFixed(2)}:1 needs ${need} (${px}px)`,
                el: (el.className || el.tagName).toString().slice(0, 30), text: t.slice(0, 34)});
    }
  });

  // 11. a control with no name is a control a screen reader cannot offer
  main.querySelectorAll("button,a[href],[role=button]").forEach(el => {
    if (!vis(el)) return;
    const name = (el.getAttribute("aria-label") || el.getAttribute("title") ||
                  el.textContent || "").replace(/\s+/g, " ").trim();
    if (!name) out.push({kind: "control-unnamed", el: (el.className || el.tagName).toString().slice(0, 40)});
  });

  // 12. two controls whose boxes overlap — one of them cannot be clicked
  const ctl = [...main.querySelectorAll("button,a[href],input,select")].filter(vis)
    .map(el => ({el, r: el.getBoundingClientRect()}))
    .filter(x => x.r.width > 2 && x.r.height > 2);
  for (let i = 0; i < ctl.length; i++) for (let j = i + 1; j < ctl.length; j++) {
    const a = ctl[i], b2 = ctl[j];
    if (a.el.contains(b2.el) || b2.el.contains(a.el)) continue;
    const ov = Math.max(0, Math.min(a.r.right, b2.r.right) - Math.max(a.r.left, b2.r.left)) *
               Math.max(0, Math.min(a.r.bottom, b2.r.bottom) - Math.max(a.r.top, b2.r.top));
    if (ov > 16) out.push({kind: "controls-overlap", detail: `${Math.round(ov)}px²`,
      text: (a.el.textContent || "").trim().slice(0, 18) + " / " + (b2.el.textContent || "").trim().slice(0, 18)});
  }

  // 13. a heading level skipped — the outline a screen reader walks has a hole
  const lv = [...main.querySelectorAll("h1,h2,h3,h4,h5,h6")].filter(vis)
    .map(h => +h.tagName[1]);
  for (let i = 1; i < lv.length; i++)
    if (lv[i] - lv[i - 1] > 1)
      out.push({kind: "heading-skip", detail: `h${lv[i - 1]} then h${lv[i]}`});

  // 14. a toggle group with nothing pressed says the state is off when it is not
  main.querySelectorAll("[role=group]").forEach(g => {
    const btns = [...g.querySelectorAll("[aria-pressed]")].filter(vis);
    if (!btns.length) return;
    const on = btns.filter(b3 => b3.getAttribute("aria-pressed") === "true").length;
    if (on !== 1) out.push({kind: "toggle-group-state", detail: `${on} of ${btns.length} pressed`,
      text: (g.getAttribute("aria-label") || "").slice(0, 24)});
  });

  // 15. a link that opens a new tab without severing the opener
  main.querySelectorAll('a[target="_blank"]').forEach(a => {
    if (!/noopener|noreferrer/.test(a.getAttribute("rel") || ""))
      out.push({kind: "blank-without-noopener", detail: (a.getAttribute("href") || "").slice(0, 44)});
  });

  // 16. the same sentence twice on one screen — the redundancy that keeps
  //     getting reported by eye, found by counting instead
  //     ADJACENT repeats only. Twenty claims that settle on the same day carry
  //     the same deadline sentence twenty times, correctly — that is the data
  //     saying the same thing about different rows, not the page saying it
  //     twice. What is a defect is one statement made twice where a reader sees
  //     both at once, which is what "within 140px of each other" tests for.
  const said = new Map();
  main.querySelectorAll("p,li,span.m,.sub,.page-sub,.small").forEach(el => {
    if (!vis(el)) return;
    const t = (el.textContent || "").replace(/\s+/g, " ").trim();
    if (t.length < 25) return;
    // Keyed by the BLOCK the sentence sits in. Two docket rows a hundred pixels
    // apart carrying the same deadline are two claims that settle the same day —
    // the data repeating, correctly. A defect is one block saying a thing twice.
    const block = el.closest(".crow,.ticket,.panel,.line,section,.gbar") || main;
    if (!said.has(block)) said.set(block, new Map());
    const m2 = said.get(block);
    (m2.get(t) || m2.set(t, []).get(t)).push(el.getBoundingClientRect().top);
  });
  [...said.values()].forEach(m2 => [...m2.entries()].forEach(([t, tops]) => {
    if (tops.length < 2) return;
    tops.sort((a, b2) => a - b2);
    for (let i = 1; i < tops.length; i++)
      if (tops[i] - tops[i - 1] < 140) {
        out.push({kind: "sentence-repeated", detail: `${Math.round(tops[i] - tops[i - 1])}px apart`,
                  text: t.slice(0, 46)});
        return;
      }
  }));

  // ---- third wave: reachable, named, unique -------------------------------

  // 17. a duplicate id is a getElementById that returns the wrong element
  const ids = new Map();
  document.querySelectorAll("[id]").forEach(el => ids.set(el.id, (ids.get(el.id) || 0) + 1));
  [...ids.entries()].filter(([, n]) => n > 1)
    .forEach(([id, n]) => out.push({kind: "duplicate-id", detail: `#${id} x${n}`}));

  // 18. an affordance that only a mouse can reach. title= shows on hover and
  //     nowhere else — no keyboard reaches it, no touch screen shows it — so an
  //     element whose ONLY explanation is a title is explained to some readers
  //     and not others. Skipped where the element is also a link or button with
  //     its own visible text, where the title is a supplement rather than the
  //     whole story.
  //     AN AFFORDANCE, NOT METADATA. The distinction is what the visible content
  //     PROMISES. "?" promises an explanation and delivers it only to a mouse —
  //     that is the defect, and it shipped twice here. A timeline row that reads
  //     "opened / 4 Sep 2026" and carries the block height in a title promises
  //     nothing it fails to deliver: the label is the content, the height is a
  //     reference, and the chain's own page carries it for anyone who wants it.
  //     So this fires on glyph-only elements — a mark whose whole job is to be
  //     asked about.
  main.querySelectorAll("[title]").forEach(el => {
    if (!vis(el)) return;
    const own = (el.textContent || "").replace(/\s+/g, " ").trim();
    if (!own || /[a-z0-9]{2}/i.test(own)) return;   // it says a word — it is a label
    // A mark that carries its sentence for a screen reader beside it is not
    // explained to a mouse ALONE. Inside a link there is nowhere to put a
    // control — a button in an anchor swallows its own click — so title plus
    // sr-only is the most that surface can offer, and it is offered.
    const sib = el.parentElement && el.parentElement.querySelector(".sr-only");
    if (sib && sib.textContent.trim() === (el.getAttribute("title") || "").trim()) return;
    out.push({kind: "title-only-affordance", detail: (el.getAttribute("title") || "").slice(0, 40),
              el: (el.className || el.tagName).toString().slice(0, 30), text: own.slice(0, 12)});
  });

  // 22. an image with no alt at all — a decorative one says alt=""
  main.querySelectorAll("img").forEach(im => {
    if (!vis(im)) return;
    if (!im.hasAttribute("alt"))
      out.push({kind: "img-no-alt", detail: (im.getAttribute("src") || "").slice(0, 50)});
  });

  // 23. tab order that jumps backwards up the page — a keyboard reader is
  //     walked somewhere they have already been
  const tabbable = [...main.querySelectorAll("a[href],button,input,select,textarea,[tabindex]")]
    .filter(el => vis(el) && el.getAttribute("tabindex") !== "-1" && !el.disabled);
  let jumps = 0;
  for (let i = 1; i < tabbable.length; i++) {
    const a = tabbable[i - 1].getBoundingClientRect(), b2 = tabbable[i].getBoundingClientRect();
    if (b2.top < a.top - 80) jumps++;
  }
  if (jumps > 2) out.push({kind: "tab-order-jumps-back", detail: `${jumps} of ${tabbable.length}`});

  // 24. a control inside another control — the inner one may be unreachable and
  //     the outer one activates when you meant the inner
  main.querySelectorAll("a[href],button").forEach(el => {
    const inner = el.querySelector("a[href],button");
    if (inner) out.push({kind: "nested-control", detail: el.tagName + " > " + inner.tagName,
                         text: (el.textContent || "").trim().slice(0, 26)});
  });

  // 19. SC 2.5.3: a control's accessible name must contain its visible label, or
  //     "click the button that says X" fails for anyone driving by voice
  main.querySelectorAll("a[href],button,[role=button]").forEach(el => {
    if (!vis(el)) return;
    const seen = (el.textContent || "").replace(/\s+/g, " ").trim().toLowerCase()
      .replace(/[→↗?×·]/g, "").trim();
    const name = (el.getAttribute("aria-label") || "").replace(/\s+/g, " ").trim().toLowerCase();
    if (!name || seen.length < 3) return;
    if (!name.includes(seen))
      out.push({kind: "label-not-in-name", detail: `says "${seen.slice(0, 22)}" named "${name.slice(0, 26)}"`});
  });

  // 20. an input nobody named
  main.querySelectorAll("input,select,textarea").forEach(el => {
    if (!vis(el) || el.type === "hidden") return;
    const lab = el.getAttribute("aria-label") || el.getAttribute("aria-labelledby") ||
      (el.id && document.querySelector(`label[for="${CSS.escape(el.id)}"]`)) ||
      el.closest("label") || el.getAttribute("placeholder");
    if (!lab) out.push({kind: "input-unnamed", el: (el.className || el.id || el.type).toString().slice(0, 30)});
  });

  // 21. a focus stop you cannot see — SC 2.4.7. Compared against the element's
  //     own resting style, so a control that changes ANYTHING on focus passes.
  //     tabindex="-1" is a PROGRAMMATIC focus target, not a keyboard stop — the
  //     route puts focus on the page heading after a navigation so a screen
  //     reader lands on the new page. Nobody tabs to it, so it needs no
  //     indicator, and reporting it buries the stops that do.
  const stops = [...main.querySelectorAll("a[href],button,input,select,[tabindex]")]
    .filter(el => vis(el) && el.getAttribute("tabindex") !== "-1").slice(0, 40);
  stops.forEach(el => {
    const before = getComputedStyle(el);
    const rest = [before.outlineStyle, before.outlineWidth, before.boxShadow,
                  before.backgroundColor, before.borderColor, before.color, before.textDecorationColor].join("|");
    el.focus({preventScroll: true});
    const after = getComputedStyle(el);
    const foc = [after.outlineStyle, after.outlineWidth, after.boxShadow,
                 after.backgroundColor, after.borderColor, after.color, after.textDecorationColor].join("|");
    if (rest === foc)
      out.push({kind: "focus-invisible", el: (el.className || el.tagName).toString().slice(0, 30),
                text: (el.textContent || "").trim().slice(0, 22)});
    el.blur();
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
