// Certified copies: static, pre-rendered embeds under web/embed/.
//
// WHAT THIS IS FOR. #/embed/<slug>/<id> is a hash route into the whole
// application: an impression costs a 600KB index.html and, measured on
// kourt.xyz, 34 RPC round trips — and an embed renders once for every VISITOR
// of whoever pasted it, so that read count is the one number that multiplies
// if anything is ever shared widely. A pre-rendered copy costs one static file
// and no chain reads at all, which is a shape a CDN can hold.
//
// WHY "CERTIFIED COPY". A clerk issues a certified copy of a record: an
// official copy, stamped with the moment it was taken. That stamp is the whole
// reason this design is honest rather than merely fast — a static copy IS
// stale, and saying as-of-when turns the staleness from a defect into the
// document's own terms. Every file carries the height it was drawn at.
//
// WHY IT LIFTS THE PAGE'S CHART INSTEAD OF DRAWING ONE. Reported as "the claim
// page has a nice looking graph, the share link iframe does not", and the cause
// is that embedSpark is a second implementation of signalChart: 75 lines against
// 303, a different mark set (seam/evt/evtDot against wash/washf/endS/ev), a
// bare .sidetag where the page has .sidetag.vtag.y, and a hover handler that
// looks for marks the embed never draws.
// Parameterising a 303-line chart built for 640x150 to also serve 300x76 is how
// the chart that currently looks good gets broken — its own comments explain
// that the two boxes need opposite label treatments. So this does not reproduce
// the chart. It renders the real claim page, lifts the .bigchart out of it, and
// writes that. The copy cannot drift from the page because it is cut from it.
//
// THE CSS IS COLLECTED, NOT COPIED. Inlining the page's whole <style> would put
// 218KB of rules behind a card that needs a few dozen — so the rules are
// gathered by asking which ones actually match the lifted subtree, which is the
// same question a critical-CSS pass asks and needs no list to maintain.
"use strict";
const fs = require("fs");
const path = require("path");

const SITE = process.env.COPY_SITE || "https://kourt.xyz";
const OUTDIR = path.join(__dirname, "..", "web", "embed");

let puppeteer;
try { puppeteer = require("puppeteer"); }
catch (_) {
  console.log("make-copies: puppeteer not installed — no copies written");
  process.exit(0);
}

// WHAT IS PRE-RENDERED IS THE EMBED, NOT THE CLAIM PAGE, and that is the
// correction that made this work. The first cut lifted the claim page's chart
// into a document of its own and collected the CSS rules that matched it — and
// produced a broken card: light theme, the title in a narrow column, page
// chrome in the breadcrumb, the stake bar stripped to a bare green/red block.
// Selecting rules cannot save a layout that positions itself against parents
// that are no longer there.
// The embed route already solves that: its markup is built to stand alone in a
// bare iframe. So the copy is the EMBED's markup, with the claim page's chart
// swapped in for its own — which is what "the same graph as the claim page"
// asks for, and it needs no reworking of a 303-line renderer built for a box
// four times the width.
//
// THE WHOLE STYLESHEET IS INLINED. 218KB of CSS is about 30KB over the wire
// gzipped, against the 630KB bundle and 34 chain reads it replaces — so
// selecting rules buys nothing measurable and costs the correctness above.
"use strict";
const SEL_CHART = ".bigchart";

async function liftChart(page, slug, id) {
  await page.goto(`${SITE}/#/c/${slug}/${id}`, {waitUntil: "domcontentloaded"});
  for (let i = 0; i < 40; i++) {
    if (await page.evaluate(s => !!document.querySelector(s + " svg .ln"), SEL_CHART)) break;
    await new Promise(r => setTimeout(r, 500));
  }
  return page.evaluate(async (s) => {
    const c = document.querySelector(s);
    const slug = location.hash.match(/c\/([a-z0-9-]+)/)[1];
    const id = +location.hash.match(/\/(\d+)/)[1];
    let stamp = {h: null, t: null};
    try {
      const d = await claimDetail(slug, id);
      const tl = await claimTimeline(slug, id, d).catch(() => null);
      if (tl && tl.now) stamp = {h: tl.now.h, t: tl.now.t};
    } catch (_) {}
    return {chart: c ? c.outerHTML : null, stamp,
            theme: document.documentElement.getAttribute("data-theme")
                   || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")};
  }, SEL_CHART);
}

// The embed, rendered, with the page's chart put in place of its own.
async function liftEmbed(page, slug, id, chartHtml, theme) {
  await page.goto(`${SITE}/#/embed/${slug}/${id}`, {waitUntil: "domcontentloaded"});
  for (let i = 0; i < 40; i++) {
    if (await page.evaluate(() => !!document.querySelector(".emb"))) break;
    await new Promise(r => setTimeout(r, 500));
  }
  // Give its own async fills a moment to land before anything is taken.
  await new Promise(r => setTimeout(r, 4000));
  return page.evaluate((chart, theme) => {
    const emb = document.querySelector(".emb");
    if (!emb) return {err: "the embed never mounted"};
    if (chart) {
      /* THE SWAP. embedSpark's chart is whatever it drew — a spark, or the
         "no recorded path" line when it had fewer than two points. Either is
         replaced, so the copy carries the page's drawing in both cases. */
      /* .esparkwrap, NOT .espark: embedSpark returns the figure AND a .espan
         date row as siblings inside that wrapper, so swapping the figure alone
         left the row behind and the copy printed the dates twice — once from
         the page chart's own axis and once from the embed's, three lines apart
         and in two different formats. .enopath is the unwrapped fallback it
         returns instead when it had fewer than two points. */
      const mine = emb.querySelector(".esparkwrap, .enopath");
      if (mine) mine.outerHTML = chart;
      else emb.querySelector(".etitle").insertAdjacentHTML("afterend", chart);
    }
    // Nothing that runs, and nothing that points at a live control.
    emb.querySelectorAll("script,button,[onclick]").forEach(e => e.remove());
    const css = [...document.querySelectorAll("style")].map(e => e.textContent).join("\n");
    /* THE ICON COMES TOO, and leaving it out cost 622KB per impression. A
       document that declares no icon makes the browser ask for /favicon.ico,
       and that path has no file behind it — so nginx's SPA fallback answered
       with index.html, 637KB of markup delivered as an image. Measured on the
       served copy: two requests, 120KB for the card and 622KB for the icon
       that was really the whole application. The page's own icon is an inline
       data: URI, which is why the application itself never asks. */
    const icon = document.querySelector('link[rel~="icon"]');
    return {emb: emb.outerHTML, css, theme: theme || null,
            icon: icon ? icon.outerHTML : ""};
  }, chartHtml, theme);
}

const esc = s => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

function pageHtml(slug, id, o) {
  const asOf = o.stamp.h != null
    ? `as of block ${Number(o.stamp.h).toLocaleString("en-US")}` : "as taken";
  return `<!doctype html><html lang="en" data-theme="${esc(o.theme || "dark")}"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kourt — ${esc(slug)} #${esc(String(id))}</title>
${o.icon || ""}
<!-- A CERTIFIED COPY of this claim's record, cut from the pages themselves: the
     embed's own markup, carrying the claim page's chart. No script and no chain
     read — this file is the whole of what it needs, which is what lets a CDN
     hold it. Stamped ${esc(asOf)}; regenerate with scripts/make-copies.js. -->
<style>
${o.css}
/* The copy stands alone, so it owns its own margins. */
html,body{margin:0;background:var(--paper);color:var(--ink)}
/* The stamp reads as part of the record, beside the source line the embed
   already carries — not as a caption stuck underneath the card. */
.cc-stamp{font:11px/1.4 var(--mono,monospace);color:var(--muted);display:block;
  margin-top:6px}
</style>
${o.emb.replace(/<\/div>\s*$/, `<span class="cc-stamp">${esc(asOf)}</span></div>`)}
</html>
`;
}

/* EVERY CLAIM, ASKED OF THE SITE ITSELF. listCourts() and listClaims() are the
   page's own readers, so enumeration happens in the browser this already drives
   rather than by lifting them into node — the same reason the chart is lifted
   from a rendered page instead of reimplemented. Named targets still win, which
   is what makes a single copy cheap to remake by hand. */
async function enumerate(page) {
  await page.goto(`${SITE}/#/`, {waitUntil: "domcontentloaded"});
  for (let i = 0; i < 30; i++) {
    if (await page.evaluate(() => typeof listCourts === "function")) break;
    await new Promise(r => setTimeout(r, 400));
  }
  return page.evaluate(async () => {
    const out = [];
    const courts = await listCourts().catch(() => []);
    for (const c of courts) {
      const slug = c.slug || c.courtSlug || c;
      if (!slug) continue;
      const claims = await listClaims(slug).catch(() => []);
      for (const cl of claims) if (cl && cl.id != null) out.push(slug + "/" + cl.id);
    }
    return out;
  });
}

(async () => {
  const args = process.argv.slice(2).filter(a => !a.startsWith("--"));
  /* ONE RUN AT A TIME. A full pass over every claim took 523 SECONDS measured
     — 41 copies, one tab, serially — so a five-minute cron would start its
     successor before its predecessor finished, and two runs writing the same
     files is how a half-written copy gets served. The lock is the guarantee;
     the concurrency below is what makes the cadence achievable at all. */
  const LOCK = path.join(OUTDIR, ".lock");
  fs.mkdirSync(OUTDIR, {recursive: true});
  try {
    fs.writeFileSync(LOCK, String(process.pid), {flag: "wx"});
  } catch (_) {
    const held = (() => { try { return fs.readFileSync(LOCK, "utf8").trim(); } catch (e) { return "?"; } })();
    const age = (() => { try { return Math.round((Date.now() - fs.statSync(LOCK).mtimeMs) / 1000); } catch (e) { return -1; } })();
    /* A LOCK OUTLIVES A CRASH, so it cannot be trusted for ever. Twenty minutes
       is well past the slowest measured run and short enough that one killed
       process does not stop the cron until somebody notices. */
    if (age >= 0 && age < 1200) {
      console.log(`make-copies: a run started ${age}s ago (pid ${held}) still holds the lock — skipping`);
      process.exit(0);
    }
    console.error(`make-copies: breaking a stale lock (pid ${held}, ${age}s old)`);
    fs.writeFileSync(LOCK, String(process.pid));
  }
  const release = () => { try { fs.unlinkSync(LOCK); } catch (_) {} };
  process.on("exit", release);

  const browser = await puppeteer.launch({headless: "new", args: ["--no-sandbox"]});
  const first = await browser.newPage();
  const want = args.length ? args : await enumerate(first);
  await first.close();
  if (!want.length) { console.error("make-copies: nothing to copy — the directory read nothing"); await browser.close(); process.exit(1); }
  if (!args.length) console.log(`make-copies: ${want.length} claim(s) from the directory`);

  /* FOUR TABS. 523s serially is 12.7s a claim, and almost all of it is waiting
     for a page to settle rather than anything this process computes — so the
     work parallelises nearly linearly. Four is chosen against the node rather
     than the CPU: the chain reads behind these pages are cached at the edge for
     five seconds, so four tabs asking the same questions mostly hit that cache
     instead of the chain. */
  const LANES = Number(process.env.COPY_LANES || 4);
  let next = 0, wrote = 0, failed = 0;
  const lane = async () => {
    const page = await browser.newPage();
    let reads = 0;
    page.on("request", r => { if (/\/status|abci_query/.test(r.url())) reads++; });
    await page.setViewport({width: 420, height: 900, deviceScaleFactor: 1});
    for (;;) {
      const i = next++;
      if (i >= want.length) break;
      const [slug, idS] = want[i].split("/");
      const id = parseInt(idS, 10);
      reads = 0;
      try {
        const c = await liftChart(page, slug, id);
        if (!c.chart) { console.error(`make-copies: ${want[i]} — the claim page's chart never drew`); failed++; continue; }
        const e = await liftEmbed(page, slug, id, c.chart, c.theme);
        if (e.err) { console.error(`make-copies: ${want[i]} — ${e.err}`); failed++; continue; }
        const dir = path.join(OUTDIR, slug);
        fs.mkdirSync(dir, {recursive: true});
        /* WRITTEN ASIDE AND MOVED INTO PLACE. nginx may be serving the old copy
           while this writes the new one, and a reader must never get half a
           file — rename within a filesystem is atomic, a write in place is not. */
        const file = path.join(dir, idS + ".html");
        const tmp = file + ".new";
        fs.writeFileSync(tmp, pageHtml(slug, id, {emb: e.emb, css: e.css, theme: e.theme,
                                                  icon: e.icon, stamp: c.stamp}));
        fs.renameSync(tmp, file);
        console.log(`make-copies: web/embed/${slug}/${idS}.html — `
          + `${Math.round(fs.statSync(file).size / 1024)}KB, `
          + `${c.stamp.h != null ? "block " + c.stamp.h : "unstamped"}, `
          + `${reads} chain reads to make, 0 to serve`);
        wrote++;
      } catch (err) {
        console.error(`make-copies: ${want[i]} — ${String(err.message).slice(0, 120)}`);
        failed++;
      }
    }
    await page.close();
  };
  await Promise.all(Array.from({length: Math.min(LANES, want.length)}, lane));
  await browser.close();
  console.log(`make-copies: ${wrote} written, ${failed} failed`);
  process.exit(failed && !wrote ? 1 : 0);
})();
