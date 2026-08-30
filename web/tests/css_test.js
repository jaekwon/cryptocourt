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

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
