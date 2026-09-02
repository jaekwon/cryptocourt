// Court livelihood chart: the grammar it parses, and the shape it draws.
//
// WHY THIS EXISTS. The chart reads a wire format the realm defines (SupplySeries
// and BurnSeries in realm/r/kourtv2/supplyseries.gno) and turns it into two
// paths. Both halves drift silently: a grammar change makes the parser return
// null and the chart just disappears, and a maths slip draws a line that is
// wrong rather than absent. Neither shows up as an error in a browser.
//
// THE STEP IS THE POINT. Both series hold flat between events and jump at one,
// so the path must be hold-then-jump. Joining the change points directly would
// draw a gradual slope that never happened — the chart would be claiming a
// history the chain does not have.
//
// TWO SERIES, NOT ONE, and separate scales. Supply rises on emissions nobody
// paid for; burn moves only when somebody spent. Read together they tell a
// dormant court apart from a growing one, which neither does alone.
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
global.ccSym = () => "KOURT:X";
global.fmtN = n => String(n);
eval(grab("parseSeries"));
eval(grab("lastEpoch"));
eval(grab("stepPath"));
eval(grab("courtLifeChartSvg"));

let fail = 0;
function ok(what, cond){ if(cond){ console.log("ok: " + what); } else { fail++; console.log("FAIL: " + what); } }

// ---- the grammar ----
const burn = parseSeries("720,40,0;10:1000,20:3000");
ok("header fields are read", burn.width === 720 && burn.now === 40 && burn.more === false);
ok("change points are read in order", burn.pts.length === 2 && burn.pts[0].e === 10 && burn.pts[1].v === 3000);
ok("more=1 is read", parseSeries("720,5,1;1:2").more === true);
// A malformed answer must produce no chart rather than a wrong one.
ok("garbage is refused", parseSeries("nonsense") === null);
ok("an empty answer is refused", parseSeries("") === null);
ok("a court with no history parses to no points", parseSeries("720,5,0;").pts.length === 0);

// ---- the step ----
const X = e => e.toFixed(1), Y = v => v.toFixed(1);
const d = stepPath(burn, X, Y).split(" ");
const xy = t => t.replace(/^[ML]/, "").split(",").map(Number);
ok("one hold and one jump per later point, plus the tail", d.length === 4);
ok("the jump is vertical — this is what makes it a step", xy(d[1])[0] === xy(d[2])[0]);
ok("the hold is horizontal", xy(d[0])[1] === xy(d[1])[1]);
ok("the tail runs flat to now", xy(d[3])[1] === xy(d[2])[1]);

// ---- the drawing ----
ok("no series at all draws nothing", courtLifeChartSvg(null, null, "x", 4) === "");
ok("empty series draw nothing", courtLifeChartSvg(parseSeries("720,5,0;"), null, "x", 4) === "");

const supply = parseSeries("720,40,0;12:500,30:900");
const svg = courtLifeChartSvg(burn, supply, "x", 4);
ok("burn is a filled area, closed to the baseline", /class="burn"[^>]*d="[^"]*Z"/.test(svg));
ok("supply is a line, not closed", /class="supply"[^>]*d="[^"]*"/.test(svg) && !/class="supply"[^>]*d="[^"]*Z"/.test(svg));
ok("both series are drawn", svg.includes('class="burn"') && svg.includes('class="supply"'));
ok("there is a baseline axis", svg.includes('class="axis"'));
ok("nothing renders NaN", !svg.includes("NaN"));
// Separate scales: each series must reach its own top, or the smaller one
// flattens into the axis and says nothing.
const burnD = svg.match(/class="burn" d="([^"]+)"/)[1];
const supD  = svg.match(/class="supply" d="([^"]+)"/)[1];
const ys = p => p.split(" ").map(t=>xy(t)[1]).filter(Number.isFinite);
ok("each series is scaled to its own maximum", Math.min(...ys(burnD)) === Math.min(...ys(supD)));

// The legend has to name what is what, and carry the current print.
ok("the legend names burn", svg.includes("GNOT burned in"));
ok("the legend names supply with the court's symbol", svg.includes("KOURT:X supply"));
ok("the current print is shown", svg.includes("print now 4"));
// A missing price prints nothing rather than a wrong number.
ok("an unknown print is omitted", !courtLifeChartSvg(burn, supply, "x", null).includes("print now"));

// One series alone must still draw — a court can burn without minting yet.
ok("burn alone draws", courtLifeChartSvg(burn, null, "x", 4).includes('class="burn"'));
ok("supply alone draws", courtLifeChartSvg(null, supply, "x", 4).includes('class="supply"'));
// A single change point has no span; it must not divide by zero.
ok("a single point draws", !courtLifeChartSvg(parseSeries("720,9,0;3:500"), null, "x", 4).includes("NaN"));

// ---- the wiring ----
ok("the court stats read SupplySeries", src.includes('one(`SupplySeries(${s})`).catch(()=>null)'));
ok("the court stats read BurnSeries", src.includes('one(`BurnSeries(${s})`).catch(()=>null)'));
ok("the chart is drawn from both reads",
  src.includes("courtLifeChartSvg(parseSeries(s.burnHist), parseSeries(s.supplyHist), slug, s.price)"));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
