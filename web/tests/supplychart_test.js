// The court page's three histories: price, supply, and GNOT burned.
//
// WHY THIS EXISTS. All three read a wire format the realm defines (SupplySeries,
// BurnSeries and PriceSeries in realm/r/kourtv2/supplyseries.gno) and turn it
// into a path. Both halves drift silently: a grammar change makes the parser
// return null and the graph just disappears, and a maths slip draws a line that
// is wrong rather than absent. Neither shows up as an error in a browser.
//
// THE STEP IS THE POINT. Every series holds flat between events and jumps at
// one, so the path must be hold-then-jump. Joining the change points directly
// would draw a gradual slope that never happened — the graph would be claiming
// a history the chain does not have.
//
// NOTHING RATHER THAN A FLAT LINE. A court with no history draws no spark at
// all, because an empty box reads as "no growth" when the truth is "nothing has
// happened yet". Burn says so in words instead, since that is the figure a
// reader is actually asking about.
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
global.fmtN = n => String(n);
global.ugnot = n => fmtN(n) + " µGNOT";
eval(grab("parseSeries"));
eval(grab("lastEpoch"));
eval(grab("stepPath"));
eval(grab("seriesScales"));
eval(grab("tileSpark"));
eval(grab("burnSectionHtml"));

let fail = 0;
function ok(what, cond){ if(cond){ console.log("ok: " + what); } else { fail++; console.log("FAIL: " + what); } }

// ---- the grammar, shared by all three reads ----
const two = parseSeries("720,40,0;10:1000,20:3000");
ok("header fields are read", two.width === 720 && two.now === 40 && two.more === false);
ok("change points are read in order", two.pts.length === 2 && two.pts[0].e === 10 && two.pts[1].v === 3000);
ok("more=1 is read", parseSeries("720,5,1;1:2").more === true);
ok("garbage is refused", parseSeries("nonsense") === null);
ok("an empty answer is refused", parseSeries("") === null);
ok("a court with no history parses to no points", parseSeries("720,5,0;").pts.length === 0);

// ---- the step ----
const d = stepPath(two, e => e.toFixed(1), v => v.toFixed(1)).split(" ");
const xy = t => t.replace(/^[ML]/, "").split(",").map(Number);
ok("one hold and one jump per later point, plus the tail", d.length === 4);
ok("the jump is vertical — this is what makes it a step", xy(d[1])[0] === xy(d[2])[0]);
ok("the hold is horizontal", xy(d[0])[1] === xy(d[1])[1]);
ok("the tail runs flat to now", xy(d[3])[1] === xy(d[2])[1]);

// ---- the tile sparks (price and supply) ----
ok("no series draws no spark", tileSpark(null) === "");
ok("an empty series draws no spark", tileSpark(parseSeries("720,5,0;")) === "");
const spark = tileSpark(two);
ok("a spark is an svg path", spark.includes("<svg") && spark.includes("<path"));
ok("a spark is decorative, not announced twice", spark.includes('aria-hidden="true"'));
ok("a spark has no axis or label at tile size", !spark.includes("axis") && !spark.includes("<text"));
ok("a spark renders no NaN", !spark.includes("NaN"));
ok("a single point still draws", !tileSpark(parseSeries("720,9,0;3:500")).includes("NaN"));
// A rise must go up: screen y grows downward, so a bigger value is a smaller y.
const sp = spark.match(/ d="([^"]+)"/)[1].split(" ");
ok("a rising series draws upward", xy(sp[2])[1] < xy(sp[0])[1]);

// ---- the burn section ----
const none = burnSectionHtml(parseSeries("720,5,0;"), "x", 0);
ok("a court with no burn says so in words", none.includes("nothing yet") && !none.includes("<path"));
ok("the empty state still carries the heading", none.includes("GNOT burned since inception"));

const burn = burnSectionHtml(two, "x", 3000);
ok("burn draws a filled area closed to the baseline", /class="burn" d="[^"]*Z"/.test(burn));
ok("burn has a baseline axis", burn.includes('class="axis"'));
ok("burn is announced to a screen reader", burn.includes('role="img"') && burn.includes("aria-label"));
ok("the running total is shown", burn.includes("3000 µGNOT"));
ok("burn renders no NaN", !burn.includes("NaN"));
ok("a capped history says older points were dropped",
  burnSectionHtml(parseSeries("720,40,1;10:5"), "x", 5).includes("older points dropped"));
ok("an uncapped history does not", !burn.includes("older points dropped"));
// A missing total prints nothing rather than a wrong number.
ok("an unknown total is omitted", !burnSectionHtml(two, "x", null).includes("µGNOT"));

// ---- the wiring ----
ok("the court stats read PriceSeries", src.includes('one(`PriceSeries(${s})`).catch(()=>null)'));
ok("the court stats read SupplySeries", src.includes('one(`SupplySeries(${s})`).catch(()=>null)'));
ok("the court stats read BurnSeries", src.includes('one(`BurnSeries(${s})`).catch(()=>null)'));
ok("the court stats read the burn total", src.includes('one(`CourtBurnedGNOT(${s})`).catch(()=>null)'));
ok("the price tile carries its own spark", src.includes("tileSpark(parseSeries(s.priceHist))"));
ok("the supply tile carries its own spark", src.includes("tileSpark(parseSeries(s.supplyHist))"));
ok("the burn section is drawn from the burn read",
  src.includes("burnSectionHtml(parseSeries(s.burnHist), slug, s.burned)"));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
