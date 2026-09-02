// DocketSeries: one read for the whole docket, four per row when the chain has
// no such entrypoint.
//
// WHY THIS HARNESS. The saving is real (56 queries become 1) but it is paid for
// with a wire format — nine colon-separated fields, twice — and a page served
// from a static host has no idea which build of the realm it is pointed at. Two
// things can therefore go wrong silently: the packed row could be mapped into
// the wrong keys, so every sparkline draws a plausible WRONG ratio; or the
// fallback could stop firing, so an older chain draws no sparklines at all and
// nothing errors. Both are invisible in a screenshot of a court page.
//
// The realm side has its own guard: docketseries_test.gno compares every packed
// field against the single reader it replaces. This is the other half — that the
// overlay reads that format back into the keys claimSeries expects.
const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "..", "index.html"), "utf8");
const { slice } = require("./srcslice");
let fail = 0;
const ok = (n, c) => { if(!c){ fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

global.WEEK = 120960;
const gstr = s => JSON.stringify(String(s));
global.gstr = gstr;

// what the chain answers, per test
let ONE = async () => { throw new Error("name DocketSeries not declared"); };
let TUPS = {};
let asked = [];
global.one = async expr => { asked.push(expr); return ONE(expr); };
global.tup = async expr => { asked.push(expr); const k = expr.split("(")[0];
  if(!TUPS[k]) throw new Error("no stub for "+k); return TUPS[k]; };

eval(slice("const DSERIES = new Map();", "async function inChunks("));

const ROW = "7:300:100:900:400:250:1:180:0";

(async () => {
  // ---- the fast path -------------------------------------------------------
  ONE = async () => ROW;
  asked = [];
  await docketSeriesPreload(gstr("orem"), [7]);
  ok("preload asks DocketSeries once, with the ids and the window",
     asked.length === 1 && /^DocketSeries\(/.test(asked[0])
     && asked[0].includes('"7"') && asked[0].endsWith(",120960)"));
  asked = [];
  const r = await docketSeriesRow(gstr("orem"), 7);
  ok("a preloaded row costs no further read", asked.length === 0);
  // THE FIELD ORDER IS THE WHOLE CONTRACT. Written out one by one rather than
  // deep-equalling an object literal, so a transposition names itself.
  ok("field 1 is the YES pool",        r.yesStake === 300);
  ok("field 2 is the NO pool",         r.noStake === 100);
  ok("field 3 is YES conviction",      r.convYes === 900);
  ok("field 4 is NO conviction",       r.convNo === 400);
  ok("field 5 is trailing OI",         r.trailOI === 250);
  ok("field 6 is the OI maturity flag",  r.trailOImature === true);
  ok("field 7 is trailing YES",        r.trailYesAvg === 180);
  ok("field 8 is the YES maturity flag", r.trailYesMature === false);
  ok("the maturity flags are booleans, not the strings '1' and '0'",
     typeof r.trailOImature === "boolean" && typeof r.trailYesMature === "boolean");

  // ---- the keys claimSeries actually reads ---------------------------------
  // A packed row that parses into the wrong NAMES draws a plausible wrong
  // ratio, which no test of the parser alone would catch.
  // claimSeries delegates to ratios(), which is where the field names are
  // actually read — checking claimSeries alone found nothing, because it only
  // passes the object along.
  const body = slice("function ratios(", "\n}");
  const wanted = ["yesStake","noStake","convYes","convNo",
                  "trailOI","trailOImature","trailYesAvg","trailYesMature"];
  ok("every key the parser writes is a key claimSeries reads",
     wanted.every(k => body.includes(k)) && wanted.every(k => k in r));

  // ---- the fallback --------------------------------------------------------
  ONE = async () => { throw new Error("name DocketSeries not declared"); };
  TUPS = {StakePools:[11,22], PoolConviction:[33,44],
          TrailingOI:[55,true], TrailingYes:[66,false]};
  asked = [];
  await docketSeriesPreload(gstr("orem"), [7]);
  ok("an older chain's refusal is swallowed, not thrown", true);
  const f = await docketSeriesRow(gstr("orem"), 7);
  ok("the fallback asks the four single readers",
     asked.filter(q => /^(StakePools|PoolConviction|TrailingOI|TrailingYes)\(/.test(q)).length === 4);
  ok("and produces the same shape as the packed row",
     f.yesStake === 11 && f.noStake === 22 && f.convYes === 33 && f.convNo === 44
     && f.trailOI === 55 && f.trailOImature === true
     && f.trailYesAvg === 66 && f.trailYesMature === false);
  ok("the fallback's keys match the packed row's, exactly",
     JSON.stringify(Object.keys(f).sort()) === JSON.stringify(Object.keys(r).sort()));

  // ---- what the wire may throw at it ---------------------------------------
  ONE = async () => "7:300:100:900:400:250:1:180:0;8:1:2:3:4:5:0:6:1";
  await docketSeriesPreload(gstr("orem"), [7,8]);
  ok("two records parse", (await docketSeriesRow(gstr("orem"),8)).yesStake === 1);
  ONE = async () => "7:300:100";                    // truncated record
  await docketSeriesPreload(gstr("orem"), [7]);
  asked = [];
  await docketSeriesRow(gstr("orem"), 7);
  ok("a short record is skipped and the row falls back rather than mis-parsing",
     asked.length === 4);
  ONE = async () => "";                              // court with no matches
  await docketSeriesPreload(gstr("orem"), [7]);
  asked = [];
  await docketSeriesRow(gstr("orem"), 7);
  ok("an empty reply falls back too", asked.length === 4);

  // ---- the cap agrees with the realm's --------------------------------------
  const capLine = /const seriesPageMax = (\d+)/.exec(
    fs.readFileSync(require("path").join(__dirname, "..", "..",
      "realm", "r", "kourtv2", "claim.gno"), "utf8"));
  ok("the realm caps a reply and the overlay asks for no more than that cap",
     !!capLine && src.includes(`claims.slice(0, ${capLine[1]})`));

  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
