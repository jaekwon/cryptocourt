// The stylesheet's own integrity: custom properties that resolve, and overlays
// that actually cover what they are drawn over.
//
// WHY THIS EXISTS. `.mapfull` — the fixed, full-viewport panel the map opens
// into — declared `background:var(--bg)`, and this stylesheet has never had a
// `--bg`. The page palette is `--paper`. An unknown custom property is NOT a CSS
// error: the declaration is dropped at computed-value time and everything else
// in the rule keeps working, so the panel laid out perfectly and rendered
// completely transparent. The claim page underneath stayed visible and the map's
// own bar drew on top of it, which the owner reported as "curate, close are
// superimposed on top of Stake on claim... basically the background is too
// visible".
//
// Twenty-two harnesses and none of them looked at the stylesheet. They slice
// JavaScript out of the page and check what it computes; CSS was assumed to be
// declarative enough not to have bugs. A typo'd variable name is a bug that no
// amount of checking the geometry can see, because the geometry was right.
const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
const css = src.slice(src.indexOf("<style>") + 7, src.indexOf("</style>"));
// Comments carry no declarations and this file's are paragraphs, so a selector
// parsed without stripping them arrives with an essay glued to its front.
const bare_css = css.replace(/\/\*[\s\S]*?\*\//g, "");

let fail = 0;
const ok = (n, c) => { if (!c) { fail++; console.log("FAIL:", n); } else console.log("ok:", n); };
const lineOf = needle => src.slice(0, src.indexOf(needle)).split("\n").length;

/* EVERY var() RESOLVES, unless it carries its own fallback. `var(--x, #fff)` is
   fine whether or not --x exists — that is what a fallback is for. `var(--x)`
   with no --x anywhere is silently nothing. */
{
  const defined = new Set([...bare_css.matchAll(/(--[\w-]+)\s*:/g)].map(m => m[1]));
  const bare = new Set();          // var(--x) with no fallback
  for (const m of bare_css.matchAll(/var\(\s*(--[\w-]+)\s*([,)])/g))
    if (m[2] === ")") bare.add(m[1]);
  const missing = [...bare].filter(v => !defined.has(v)).sort();
  ok(`every var() without a fallback names a property this sheet defines`
     + (missing.length ? ` — undefined: ${missing.join(", ")}` : ""),
     missing.length === 0);
  ok("and the sheet actually defines a palette, so the check above is not vacuous",
     defined.size > 20 && bare.size > 20);
}

/* AN OVERLAY THAT COVERS THE VIEWPORT DECLARES AN OPAQUE BACKGROUND. This is the
   shape of the bug rather than the instance of it: a rule that takes over the
   whole screen and does not paint one lets whatever it replaced show through. */
{
  const rules = [...bare_css.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .map(m => ({sel: m[1].trim().replace(/\s+/g, " "), body: m[2]}));
  const covers = rules.filter(r => /position\s*:\s*fixed/.test(r.body)
                                && /inset\s*:\s*0/.test(r.body));
  ok("the sheet has at least one full-viewport overlay to check", covers.length > 0);
  for (const r of covers)
    ok(`${r.sel} paints a background, so it covers the page it sits over`,
       /background(-color)?\s*:/.test(r.body));
}

/* `hidden` HAS TO BEAT THE RULE THAT LAYS THE LEGEND OUT. `.mlegend span` sets
   display:inline-flex, and a class selector beats the user agent's
   [hidden]{display:none} — so marking a legend key hidden does nothing at all
   unless the sheet says so itself. The key in question explains the dashed spoke
   drawn for a claim filed in two folders, and it must not sit there explaining a
   line the map did not draw. */
{
  const lays = /\.mlegend\s+span\s*\{[^}]*display\s*:/.test(bare_css);
  ok("the legend lays its keys out with display, which is what makes this needed", lays);
  ok("...so the sheet hides a marked key itself, rather than trusting [hidden]",
     /\.mlegend\s+span\[hidden\]\s*\{[^}]*display\s*:\s*none/.test(bare_css));
}

/* And the instance, named, because it is the one the owner hit. */
{
  const m = /\.mapfull\{([^}]*)\}/.exec(bare_css);
  ok("the full-screen map declares a background", !!m && /background/.test(m[1]));
  ok("...and it is the page's own paper, not a colour invented for this rule",
     !!m && /background\s*:\s*var\(--paper\)/.test(m[1]));
  if (m && !/var\(--paper\)/.test(m[1]))
    console.log(`   (.mapfull is at index.html:${lineOf(".mapfull{")})`);
}

/* ---- CHOOSING LIGHT MUST UNDO EVERY DARK VALUE -------------------------
 *
 * The palette is declared in four places: :root, @media(prefers-color-scheme
 * :dark), :root[data-theme=light] and :root[data-theme=dark]. A reader whose
 * system is dark and who picks light gets the media query's values unless the
 * light block re-declares them — so a token added to the media query and not to
 * :root[data-theme=light] keeps its DARK value on a light page, and only a
 * render in that combination shows it.
 *
 * That is how --bad arrived: added to :root and the media query, missed in both
 * data-theme blocks, and the composer's error text came out pale salmon on light
 * grey. --good had been declared in all four all along, which is the pattern.
 */
function propsIn(block) {
  const i = bare_css.indexOf(block);
  if (i < 0) return null;
  const body = bare_css.slice(i + block.length, bare_css.indexOf("}", i));
  return new Set([...body.matchAll(/(--[a-z0-9-]+)\s*:/g)].map(m => m[1]));
}
const mediaDark = (() => {
  const i = bare_css.indexOf("@media (prefers-color-scheme:dark){");
  if (i < 0) return null;
  // the block runs to the nested :root's closing brace
  const body = bare_css.slice(i, bare_css.indexOf("\n  }", i));
  return new Set([...body.matchAll(/(--[a-z0-9-]+)\s*:/g)].map(m => m[1]));
})();
const themeLight = propsIn(":root[data-theme=light]{");
const themeDark = propsIn(":root[data-theme=dark]{");
ok("the four palette blocks are all present",
   !!(mediaDark && themeLight && themeDark));
if (mediaDark && themeLight && themeDark) {
  const unLightable = [...mediaDark].filter(v => !themeLight.has(v));
  ok("every token the dark media query sets is re-set by the light theme"
     + (unLightable.length ? ` — ${unLightable.join(", ")}` : ""),
     unLightable.length === 0);
  // And the two explicit themes must offer the same vocabulary, or a rule
  // written against one resolves to nothing in the other.
  const onlyLight = [...themeLight].filter(v => !themeDark.has(v));
  const onlyDark = [...themeDark].filter(v => !themeLight.has(v));
  ok("the two explicit themes declare the same tokens"
     + (onlyLight.length || onlyDark.length
        ? ` — light-only: ${onlyLight.join(",") || "none"}; dark-only: ${onlyDark.join(",") || "none"}` : ""),
     onlyLight.length === 0 && onlyDark.length === 0);
}

// THE COURT'S FIGURE STRIP: two columns, and the edges follow from that count.
// The strip is drawn as one ruled instrument — vertical rules between cells, no
// outer edges — which only works if CSS knows which cell starts a row. It moved
// from full width into the left column, where four cells no longer fit, and the
// first two attempts to rule the wrapped grid were both wrong: at 820 the third
// cell lost its left edge, at 420 the second row lost its top one. A fixed two
// columns is the fact these three rules depend on, so assert it is not overridden
// anywhere below — a breakpoint that re-wraps the strip silently un-rules it.
{
  const stat = src.match(/\.courtstats \.grid\.stats\{([^}]*)\}/g) || [];
  ok("court stats: exactly one grid-template-columns for the in-column strip", stat.length === 1);
  ok("court stats: two columns", /repeat\(2,\s*minmax\(0,1fr\)\)/.test(stat[0] || ""));
  ok("court stats: row-start cells drop the left rule",
     /\.courtstats \.grid\.stats>div:nth-child\(2n\+1\)\{border-left:0\}/.test(src));
  ok("court stats: the second row gains a top rule",
     /\.courtstats \.grid\.stats>div:nth-child\(n\+3\)\{border-top:1px solid var\(--rule\)\}/.test(src));
  // and the strip is inside the left column, which is what puts the Join panel
  // at the top of the page instead of 200px below the header rule.
  const cols = src.indexOf('return `<div class="cols"><div id="qscope">`');
  const call = src.indexOf("+ courtStatsHtml(slug, s)", cols);
  ok("court stats: rendered as the head of the left column", cols > 0 && call > cols && call - cols < 120);
  const hs = src.indexOf('main.innerHTML = crumbs([{label:"Directory",href:"#/"},{label:s.name}])');
  const header = src.slice(hs, src.indexOf("+ courtBody(slug, s,", hs));
  ok("court stats: no second strip above the columns", !header.includes('grid stats'));
}

// THE MARK IS DRAWN IN THREE PLACES and must be one drawing: the rail, the
// favicon, and the fork-me ribbon. Nothing in a browser can tell you they have
// drifted — the tab icon is 16px and nobody compares it to the sidebar — so the
// paths are compared here. The favicon cannot share a variable with the DOM (it
// is an attribute in <head>, read before any script runs), which is exactly the
// situation that produces two copies of one shape.
{
  const paths = where => {
    const seg = src.slice(where.a, where.b);
    return (seg.match(/d=['"]([^'"]+)['"]/g) || []).map(t =>
      t.replace(/^d=['"]/, "").replace(/['"]$/, "").replace(/\s+/g, " ").trim());
  };
  const iconRaw = /<link rel="icon" href="data:image\/svg\+xml,([^"]+)"/.exec(src);
  ok("the favicon is an svg data URI", !!iconRaw);
  const icon = decodeURIComponent((iconRaw ? iconRaw[1] : "").replace(/%23/g, "#"))
    .replace(/\s+/g, " ");
  const iconPaths = (icon.match(/d='([^']+)'/g) || [])
    .map(t => t.slice(3, -1).replace(/\s+/g, " ").trim());
  const railA = src.indexOf('<span class="sir" aria-hidden="true">');
  const rail = paths({a: railA, b: src.indexOf("</svg>", railA)});
  const forkA = src.indexOf('class="forkme"');
  const fork = paths({a: forkA, b: src.indexOf("</svg>", forkA)});
  ok("the rail draws the hat, the brim and the moustache", rail.length === 3);
  ok("the favicon draws the same three paths, in the same order",
     iconPaths.length === 3 && iconPaths.every((d, i) => d === rail[i]));
  ok("the ribbon draws the same three paths, in the same order",
     fork.length === 3 && fork.every((d, i) => d === rail[i]));
  // and the favicon must not smuggle a second stylesheet into this file: a
  // literal <style> inside that attribute is what every tool slicing this file
  // on "<style>" would find first — this harness did, and started checking the
  // favicon's four rules instead of the page's thousand.
  ok("the favicon's markup is percent-encoded, so the page has ONE <style>",
     (src.match(/<style>/g) || []).length === 1);
}

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
