// Supply-chart harness: the grammar it parses, and the shape it draws.
//
// WHY THIS EXISTS. The chart reads a wire format the realm defines
// (SupplySeries in realm/r/kourtv2/supplyseries.gno) and turns it into a path.
// Both halves can drift silently: a grammar change makes the parser return
// null and the chart simply disappears, and a maths slip draws a line that is
// wrong rather than absent. Neither shows up as an error in a browser.
//
// THE STEP IS THE POINT. Supply holds flat between mints and jumps at one, so
// the path must be hold-then-jump. Joining the change points directly would
// draw a gradual rise that never happened — the chart would be claiming a
// history the chain does not have.
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'index.html'), 'utf8');

function grab(name){
  const i = src.indexOf("function " + name + "(");
  if(i < 0) throw new Error("missing " + name);
  let depth = 0;
  for(let k = src.indexOf("{", i); k < src.length; k++){
    if(src[k] === "{") depth++;
    else if(src[k] === "}"){ depth--; if(!depth) return src.slice(i, k + 1); }
  }
  throw new Error("unbalanced " + name);
}
eval(grab("parseSupplySeries"));
eval(grab("supplyChartSvg"));

let fail = 0;
function ok(what, cond){ if(cond){ console.log("ok: " + what); } else { fail++; console.log("FAIL: " + what); } }

// ---- the grammar ----
const s = parseSupplySeries("720,40,0;10:1000,20:3000");
ok("header fields are read", s.width === 720 && s.now === 40 && s.more === false);
ok("change points are read in order", s.pts.length === 2 && s.pts[0].e === 10 && s.pts[1].v === 3000);
ok("more=1 is read", parseSupplySeries("720,5,1;1:2").more === true);
// A malformed answer must produce no chart rather than a wrong one.
ok("garbage is refused", parseSupplySeries("nonsense") === null);
ok("an empty answer is refused", parseSupplySeries("") === null);
ok("a court that never minted parses to no points", parseSupplySeries("720,5,0;").pts.length === 0);

// ---- the drawing ----
ok("no points draws nothing", supplyChartSvg(parseSupplySeries("720,5,0;")) === "");

const svg = supplyChartSvg(s);
const d = svg.match(/ d="([^"]+)"/)[1].split(" ");
const xy = t => t.replace(/^[ML]/, "").split(",").map(Number);
// M, then hold+jump for the second point, then the flat tail to `now`.
ok("one hold and one jump per later point, plus the tail", d.length === 4);
ok("the jump is vertical — this is what makes it a step", xy(d[1])[0] === xy(d[2])[0]);
ok("the hold is horizontal", xy(d[0])[1] === xy(d[1])[1]);
ok("the tail runs flat to now", xy(d[3])[1] === xy(d[2])[1]);
// Screen y grows downward, so more supply must be a SMALLER y.
ok("a rise in supply draws upward", xy(d[2])[1] < xy(d[0])[1]);
ok("nothing renders NaN", !svg.includes("NaN"));

// A court with a single mint has no span and no rise; it must still draw.
const one = supplyChartSvg(parseSupplySeries("720,9,0;3:500"));
ok("a single change point draws a flat line", one.includes("<path") && !one.includes("NaN"));

// ---- the wiring ----
ok("the court stats read SupplySeries", src.includes('one(`SupplySeries(${s})`).catch(()=>null)'));
ok("the chart is drawn from that read", src.includes("supplyChartSvg(parseSupplySeries(s.supplyHist))"));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
