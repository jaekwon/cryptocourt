// The court page's one graph: GNOT burned into this court over time.
//
// WHY THIS EXISTS. It reads a wire format the realm defines (BurnSeries in
// realm/r/kourtv2/supplyseries.gno) and turns it into a path. Both halves drift
// silently: a grammar change makes the parser return null and the graph just
// disappears, and a maths slip draws a line that is wrong rather than absent.
// Neither shows up as an error in a browser.
//
// ONE GRAPH, NOT THREE. Price and supply are figures; burn is the one worth a
// shape, because it is the one nobody can fake.
//
// THE STEP IS THE POINT. Every series holds flat between events and jumps at
// one, so the path must be hold-then-jump. Joining the change points directly
// would draw a gradual slope that never happened — the graph would be claiming
// a history the chain does not have.
//
// BLANK RATHER THAN A FLAT LINE. A court with no history draws nothing, because
// a zero line reads as "no growth" when the truth is "nothing has happened
// yet". The box keeps its height so the three tiles stay level.
//
// ENDPOINTS ARE DRAWN. A flat run is the common case, and without both ends
// marked it reads as a stray rule across the tile rather than as a value that
// has held since a known point.
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
global.BLOCK_SECS = 5;
global.MON = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
eval(grab("parseSeries"));
eval(grab("lastEpoch"));
eval(grab("stepPath"));
eval(grab("seriesScales"));
eval(grab("sinceWords"));
eval(grab("anchorNow"));
eval(grab("sinceLabel"));
eval(grab("dot"));
eval(grab("tileSpark"));

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

// ---- the tile sparks ----
const spark = tileSpark(two);
ok("a spark is an svg path", spark.includes("<svg") && spark.includes("<path"));
ok("a spark is decorative, not announced twice", spark.includes('aria-hidden="true"'));
ok("a spark has no axis or label at tile size", !spark.includes("axis") && !spark.includes("<text"));
ok("a spark renders no NaN", !spark.includes("NaN"));
ok("a single point still draws", !tileSpark(parseSeries("720,9,0;3:500")).includes("NaN"));
// A rise must go up: screen y grows downward, so a bigger value is a smaller y.
const sp = spark.match(/ d="([^"]+)"/)[1].split(" ");
ok("a rising series draws upward", xy(sp[2])[1] < xy(sp[0])[1]);

// ---- endpoints and the empty state ----
// A flat run is the common case, so both ends must be marked or it reads as a
// stray rule rather than a history.
const flat = tileSpark(parseSeries("720,166,0;1:13053599975"));
ok("a single change point still draws two endpoints", (flat.match(/<line class="end"/g)||[]).length === 2);
const cx = [...flat.matchAll(/x1="([\d.]+)"/g)].map(m=>+m[1]);
ok("a single change point spans the box, not one edge", cx.length===2 && cx[1] > cx[0]);
ok("the span reaches the right edge", cx[1] >= 190);
// Two points: the ends sit at the extremes too.
const cx2 = [...tileSpark(two).matchAll(/x1="([\d.]+)"/g)].map(m=>+m[1]);
ok("two points also span the box", cx2[0] < cx2[1]);

// No data draws nothing at all — not words, not a zero line — but keeps its
// height so the three tiles stay level.
const blank = tileSpark(parseSeries("720,5,0;"));
ok("no data draws no path and no dots", !blank.includes("<path") && !blank.includes("<line"));
ok("no data says nothing in words", !/[a-z]{4}/.test(blank.replace(/class="[^"]*"/g,"")));
ok("no data still occupies the row", blank.includes("tspark-none"));
ok("a null series behaves the same", tileSpark(null).includes("tspark-none"));

// ---- the date under the graph ----
// The anchor is the realm's wall-clock reading; without one there must be no
// date at all, because a wrong date looks exactly like a right one.
ok("the anchor is read out of a timeline", anchorNow("opened:1000:5;now:1786036800:4800") === 1786036800);
ok("a timeline without a now entry yields nothing", anchorNow("opened:1000:5") === null);
ok("junk yields nothing", anchorNow("") === null && anchorNow(null) === null);
ok("a zero reading is not an anchor", anchorNow("now:0:1") === null);

// AN EPOCH IS AN HOUR: 720 blocks at 5s. So a month back is ~720 epochs, not
// 30 — the arithmetic this test got wrong the first time.
const anchor = Date.UTC(2026, 5, 15) / 1000;              // 15 Jun 2026
const ser30d = parseSeries("720,800,0;80:5,800:9");       // first point 720 epochs = 30 days ago
ok("the date and the distance, both", sinceLabel(ser30d, anchor) === "since 16 May 2026, 30 days ago");
// A span of zero gets the date alone: sinceWords reads an identical time as
// the future ("in 1 min"), which is worse than saying nothing.
ok("a zero span shows the date alone", sinceLabel(parseSeries("720,40,0;40:1"), anchor) === "since 15 Jun 2026");
ok("an hour-old start does carry its distance", /^since .+ 2026, 1 hour ago$/.test(sinceLabel(parseSeries("720,41,0;40:1"), anchor)));
// The year is never dropped, whatever the span — a date that sometimes has one
// makes the reader work out which kind it is before they can read it.
const serOld = parseSeries("720,9000,0;40:5,9000:9");   // ~1 year back
ok("an old start names its own year", /^since \d{1,2} [A-Z][a-z]{2} 2025, .+ ago$/.test(sinceLabel(serOld, anchor)));
ok("every label carries a year and a distance",
   [sinceLabel(ser30d, anchor), sinceLabel(serOld, anchor)]
     .every(l => /\b20\d\d,/.test(l) && / ago$/.test(l)));
// No anchor, no date — the graph still says the same thing without one.
ok("no anchor means no date", sinceLabel(ser30d, null) === "" && sinceLabel(ser30d, 0) === "");
ok("no data means no date", sinceLabel(parseSeries("720,5,0;"), anchor) === "");

// ---- the wiring ----
ok("the court stats read BurnSeries", src.includes('one(`BurnSeries(${s})`).catch(()=>null)'));
// Only the graph that is drawn is fetched. Reading a series nothing renders is
// a query per court page paid for nothing.
ok("no series is fetched that nothing draws",
   !src.includes("PriceSeries(${s})") && !src.includes("SupplySeries(${s})"));
ok("the court stats read the burn total", src.includes('one(`CourtBurnedGNOT(${s})`).catch(()=>null)'));
ok("burn is the tile carrying the graph", src.includes("tileSpark(burnSer)"));
// The graph fills the cell it is in rather than sitting in a fixed box.
ok("the graph stretches to the cell", src.includes('preserveAspectRatio="none"')
   && src.includes(".tspark{width:100%"));
ok("the stroke stays one weight while the box stretches",
   src.includes("vector-effect:non-scaling-stroke"));
ok("the caption is a date, not a lecture",
   src.includes("sinceLabel(burnSer, s.nowUnix)")
   && !src.includes("spent to mint the coin, never returned")
   && !src.includes('"since inception"'));
ok("the anchor is the realm's own clock, not the browser's",
   src.includes("one(`ClaimTimeline(${s},1)`).catch(()=>null)"));
ok("price and supply are figures only", (src.match(/tileSpark\(/g)||[]).length === 2);
// Dust does not earn a cell. Both extra figures are unminted claims on future
// supply, so they show only once they could move the supply figure above them.
ok("the extra figures are gated on size, not on being non-zero",
   src.includes("v >= s.supply / 100") && !src.includes("if(s.reservoir>0)"));
// GNOT, not µGNOT: three cells share the left column and the raw figure does
// not fit. Reuses the helper that already handles the sub-0.01 dust case.
ok("burn is shown in GNOT, not raw micro-units", src.includes("gnotAmt(s.burned)"));
ok("burn sits beside price and supply, three across",
  src.includes(".courtstats .grid.stats{grid-template-columns:repeat(3,minmax(0,1fr))}"));
ok("the third column's borders are keyed to three, not two",
  src.includes("nth-child(3n+1)") && src.includes("nth-child(n+4)"));

console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
process.exit(fail ? 1 : 0);
