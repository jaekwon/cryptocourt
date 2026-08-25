#!/usr/bin/env node
// Render the court map to a standalone SVG you can open, without a browser.
//
// WHY THIS EXISTS. The map is the one surface whose bug is invisible to every
// check that guards it. map_test.js slices mapLayout/mapSvg out of the page and
// verifies GEOMETRY — no overlaps, labels inside their boxes, nothing outside the
// viewBox — and a layout can satisfy all of that and still be unreadable. The
// previous one did: it passed every check for months while drawing the docket as
// a hierarchy of nested rectangles with the court itself nowhere on the page, and
// the only way anybody found out was by looking at it.
//
// So: this is the looking-at-it tool. It pulls a real court off a node (or builds
// the demo court's shape), runs the page's own mapLayout/mapSvg over it, and
// writes an SVG with the map's colours inlined — the page's stylesheet is not
// there, so without them the file renders as invisible strokes on white.
//
//   node scripts/map-preview.js --remote http://127.0.0.1:26657 --court covid
//   node scripts/map-preview.js --demo --court orem --mode ids
//   rsvg-convert -w 1100 map-preview.svg -o map-preview.png   # then look at it
//
// It reads index.html by slicing, exactly as the harnesses do, so it cannot drift
// from what the page draws: there is one implementation of the layout and this is
// not a second one.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf(k); return i < 0 ? d : argv[i + 1]; };
const REMOTE = arg("--remote", "http://127.0.0.1:26657");
const SLUG = arg("--court", "covid");
const MODE = arg("--mode", "titles");
const OUT = arg("--out", "map-preview.svg");
const DEMO = argv.includes("--demo");
const REALM = "gno.land/r/kourt/kourtv2";

const src = fs.readFileSync(path.join(__dirname, "..", "web", "index.html"), "utf8");
function slice(from, to){
  const a = src.indexOf(from); if(a < 0) throw new Error("missing " + from);
  const b = src.indexOf(to, a); if(b < 0) throw new Error("missing " + to);
  return src.slice(a, b);
}
global.esc = s => String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;")
  .replace(/>/g,"&gt;").replace(/"/g,"&quot;");
// The map only asks phaseClass for `.short`, and the real one needs half the page
// to run. A phase drives the dot's colour and nothing about the geometry.
global.phaseClass = t => ({short:
  /settled/.test(t) ? "settled" : /dispute/.test(t) ? "in dispute" :
  /never/.test(t) ? "never answered" : /answered/.test(t) ? "answered" : "open"});
eval(slice("const MAPK", "\nfunction mapDotClass").replace("const MAPK", "var MAPK"));
eval(slice("function mapDotClass", "\n/* The join panel"));

function q(expr){
  const out = execFileSync("gnokey",
    ["query","vm/qeval","-remote",REMOTE,"-data",`${REALM}.${expr}`], {encoding:"utf8"});
  for(const l of out.split("\n")){
    if(!l.startsWith("data:")) continue;
    const v = l.slice(6).trim();
    const s = /^\("([\s\S]*)" string\)$/.exec(v);
    // sanitize.InlineText escapes markdown on the way out; undo it for display.
    if(s) return s[1].replace(/\\\\-/g,"-").replace(/\\-/g,"-");
    const n = /^\((-?\d+) \w+\)$/.exec(v);
    return n ? n[1] : v;
  }
  return "";
}
const uints = e => [...q(e).matchAll(/\((\d+) uint64\)/g)].map(m => +m[1]);

function fromChain(){
  const kids = {};
  for(const row of q(`FolderTree("${SLUG}")`).split(",").filter(Boolean)){
    const [fid, par] = row.split(":");
    (kids[+par] = kids[+par] || []).push(+fid);
  }
  const build = fid => ({
    name: q(`FolderName("${SLUG}",${fid})`),
    claims: uints(`FolderItems("${SLUG}",${fid})`),
    folders: (kids[fid] || []).map(build),
    path: String(fid),
  });
  const n = +q(`ClaimCount("${SLUG}")`);
  const all = [], claims = {};
  for(let i = 1; i <= n; i++){
    const title = q(`ClaimTitle("${SLUG}",${i})`);
    if(!title) continue;               // purged or redacted: the realm withholds it
    all.push(i);
    claims[i] = {title, statusText: q(`ClaimStatus("${SLUG}",${i})`) || "open"};
  }
  const relations = [];
  for(const i of all){
    // The OUT half only: the realm reports every edge on both its claims, so
    // reading both halves would draw each one twice. Same for `of:` versus `by:`.
    const raw = q(`ClaimAssociations("${SLUG}",${i})`);
    for(const part of raw.split(";in:")[0].slice(4).split(",").filter(Boolean)){
      const [to, st] = part.split(":");
      relations.push({from:i, to:+to, type:"bears",
                      stance: st === "c" ? "contradicts" : "supports"});
    }
    const of = q(`ClaimSupersedes("${SLUG}",${i})`).split(";by:")[0].slice(3);
    if(of) relations.push({from:i, to:+of, type:"supersedes"});
  }
  return {folders:(kids[0] || []).map(build), all, claims, relations,
          courtName: q(`CourtName("${SLUG}")`) || SLUG, linkFolders:true};
}

function fromDemo(){
  let code = slice("function esc(", "\n") + slice("function fmtN(", "function ugnot(");
  const nowm = /const NOW\s*=\s*([0-9_]+)/.exec(src);
  code += `var NOW=${Number(nowm[1].replace(/_/g,""))};\n`;
  code += slice("const DEMO_OVERLAY = {", "/* ===== BEGIN GENERATED").replace("const DEMO_OVERLAY = {","var DEMO_OVERLAY = {") + "\n";
  code += slice("const DEMO_CHAIN = {", "/* ===== END GENERATED").replace("const DEMO_CHAIN = {","var DEMO_CHAIN = {") + "\n";
  code += slice("function mergeDemo(", "const DEMO = mergeDemo") + "\n";
  code += "var DEMO = mergeDemo(DEMO_CHAIN, DEMO_OVERLAY);\n";
  code += slice("function statusText(", "\n/* =");
  const ns = {};
  new Function("g", code + ";g.DEMO=DEMO;g.statusText=statusText;")(ns);
  const c = ns.DEMO.courts[SLUG];
  if(!c) throw new Error(`no demo court "${SLUG}" — try --court orem`);
  const claims = {};
  c.claims.forEach(id => { const d = ns.DEMO.claims[SLUG+"/"+id];
    claims[id] = {title:d.title, statusText:ns.statusText(d)}; });
  return {folders:c.folders, all:c.claims, claims,
          relations:(ns.DEMO.relations||{})[SLUG]||[], courtName:c.name||SLUG, linkFolders:true};
}

// The page's map colours, inlined. Light theme only: this is a look-at-it tool,
// and a preview that needed a theme switch would be a second stylesheet to keep
// in step with the first.
const CSS = `<style>
 svg{background:#faf9f7}
 .mnode{fill:#fff;stroke:#8b8578;stroke-width:1}
 .mtext{fill:#26241f;font-family:ui-sans-serif,system-ui} .mtitle{fill:#5c574c}
 .mfold{fill:#eef2fb;stroke:#3b5bdb;stroke-width:1}
 .mfold.pseudo{fill:none;stroke-dasharray:4 3;stroke:#9a948a}
 .mhdr-t{fill:#2b3fa8;font-weight:600}
 .mcourt{fill:#3b5bdb;stroke:#2b3fa8;stroke-width:1.5} .mcourt-t{fill:#fff;font-weight:700}
 .medge{fill:none;stroke:#8b8578;stroke-width:1.2}
 .medge.spoke{stroke:#cfc9bd;stroke-width:1.4} .medge.spoke.toclaim{stroke-width:1}
 .medge.spoke.also{stroke:#9a948a;stroke-width:1;stroke-dasharray:3 4}
 .medge.bears.yes{stroke:#1f8a4c;stroke-dasharray:5 4;stroke-width:1.6}
 .medge.bears.no{stroke:#c0392b;stroke-dasharray:5 4;stroke-width:1.6}
 .medge.sup{stroke:#9a948a;stroke-dasharray:2 3;stroke-width:1.6}
 .medge.part{stroke:#26241f;stroke-width:2}
 .marrow{fill:#26241f} .marrow.light{fill:#8b8578}
 .mdot.g{fill:#1f8a4c} .mdot.e{fill:#b8860b} .mdot.ed{fill:none;stroke:#b8860b;stroke-dasharray:2 2}
 .mdot.o{fill:#3b5bdb} .mdot.v{fill:none;stroke:#8b8578}
 .mdot.vd{fill:#cfc9bd} .mdot.vf{fill:none;stroke:#c0392b;stroke-dasharray:2 2}
</style>`;

const data = DEMO ? fromDemo() : fromChain();
const L = mapLayout(data, MODE);
let svg = mapSvg(L, data, SLUG).replace(">", ">" + CSS);
let note = "";
// --frame core renders what the page OPENS on rather than the whole graph. The
// two are not the same picture and the difference is the point: a map that looks
// fine fitted can still open on something unreadable, which is what it did.
if(arg("--frame", "") === "core"){
  const core = [L.court].concat(L.folders.filter(f => f.depth <= 1),
                                L.nodes.filter(n => n.depth <= 1));
  const pad = 48, cx = L.court.cx, cy = L.court.cy;
  const rx = core.reduce((m,b) => Math.max(m, Math.abs(b.x-cx), Math.abs(b.x+b.w-cx)), 0) + pad;
  const ry = core.reduce((m,b) => Math.max(m, Math.abs(b.y-cy), Math.abs(b.y+b.h-cy)), 0) + pad;
  const x0 = cx-rx, x1 = cx+rx, y0 = cy-ry, y1 = cy+ry;
  svg = svg.replace(/viewBox="[^"]+"/,
    `viewBox="${Math.round(x0)} ${Math.round(y0)} ${Math.round(x1-x0)} ${Math.round(y1-y0)}"`);
  note = ` — framed on the court and ring 1: ${Math.round(x1-x0)}x${Math.round(y1-y0)}`
       + ` (${(L.viewBox[2]/(x1-x0)).toFixed(2)}x into the fitted view)`;
}
fs.writeFileSync(OUT, svg);
const heights = [...new Set(L.nodes.map(n => n.h))].sort((a,b) => a-b);
console.log(`${OUT}: ${L.viewBox[2]}x${L.viewBox[3]}, ${L.folders.length} folder(s), `
  + `${L.nodes.length} claim(s), ${L.spokes.length} spoke(s), ${L.edges.length} chord(s)`
  + `, claim heights ${heights.join("/")}`
  + `, rings ${(L.rings||[]).join("->")}${note}`);
