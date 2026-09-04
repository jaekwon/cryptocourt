// The packed claim record, read back.
//
// WHY THIS HARNESS. ClaimHead is thirty-nine tab-separated columns read BY
// POSITION, which is the fastest wire format and the most dangerous one: a
// column inserted in the realm and not here does not fail, it slides every field
// after it into the wrong variable. A bond becomes a deadline, a verdict becomes
// a draw slice, and the page renders confidently and wrongly. Nothing in a
// screenshot shows it.
//
// The realm side has its own guard — claimhead_test.gno compares every column
// against the single reader it replaces. This is the other half: that the
// overlay maps those columns onto the names the claim page uses, and that it
// refuses rather than guesses when the record is not the shape it expects.
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const { slice } = require("./srcslice");
let fail = 0, DONE = false;
process.on("exit", () => { if(!DONE){ console.log("\nDIED BEFORE FINISHING"); process.exitCode = 1; } });
const ok = (n, c) => { if(!c){ fail++; console.log("FAIL:", n); } else console.log("ok:", n); };

global.WEEK = 120960;
global.unesc = s => String(s);
let REPLY = null, asked = [];
global.one = async e => { asked.push(e); if(REPLY instanceof Error) throw REPLY; return REPLY; };

eval(slice("const CLAIM_HEAD_FIELDS =", "async function claimDetail("));

// THE COLUMN COUNT IS THE CONTRACT, and it is written down in two places — the
// realm and this page. They are compared here rather than trusted.
const realmSrc = fs.readFileSync(
  path.join(__dirname, "..", "..", "realm", "r", "kourtv2", "claimhead.gno"), "utf8");
const realmN = Number(/const claimHeadFields = (\d+)/.exec(realmSrc)[1]);

// a record with a recognisable value in every column, so a shift is visible
const COLS = ["11","22","33","44","55","1","66","0",
              "1","0","0","0","-1","0",
              "1","777","888","g1answerer","3",
              "2","999","1010","1111","1212",
              "0","vote","1","10","20","30","40",
              "g1author","0","0","0","1","720","7","1"];
const REC = COLS.join("\t");

(async () => {
  // const inside an eval does not escape that eval's scope; the function does,
  // and closes over it. The number is read from the source instead.
  const overlayN = Number(/const CLAIM_HEAD_FIELDS = (\d+);/.exec(src)[1]);
  ok(`the overlay expects the number of columns the realm sends (${realmN})`,
     overlayN === realmN);
  ok("the fixture in this harness is that wide too", COLS.length === realmN);

  REPLY = REC; asked = [];
  const h = await claimHeadOf('"orem"', 3);
  ok("one read, and it is ClaimHead with the window",
     asked.length === 1 && /^ClaimHead\("orem",3,120960\)$/.test(asked[0]));

  // EVERY COLUMN NAMED, one assertion each. Written out rather than deep-equalled
  // so that a transposition says which two fields swapped.
  const want = {
    yesStake:11, noStake:22, convYes:33, convNo:44,
    trailOI:55, trailOImature:true, trailYesAvg:66, trailYesMature:false,
    answered:true, disputeOpen:false, settled:false, provClose:false,
    provisional:-1, closed:false,
    answer:1, answerBond:777, settleAt:888, answerer:"g1answerer", answerRecord:3,
    round:2, disputeBondNext:999, escrowUntil:1010, quorumFloor:1111, voteCloses:1212,
    verdict:0, route:"vote", rewardsOpened:true,
    drawW:10, drawA:20, drawAns:30, drawCarrot:40,
    author:"g1author", hidden:false, redacted:false, purged:false, seeded:true,
    stakeOpenDelay:720, boardSize:7, boardOpen:true,
  };
  for(const k of Object.keys(want))
    ok(`column -> ${k}`, h[k] === want[k]);
  ok("and it names nothing the page does not ask for",
     Object.keys(h).length === Object.keys(want).length);

  // ---- it refuses rather than guesses --------------------------------------
  REPLY = new Error("name ClaimHead not declared");
  ok("an older realm yields null, so the caller reads singly",
     (await claimHeadOf('"orem"', 3)) === null);
  REPLY = COLS.slice(0, realmN - 1).join("\t");
  ok("a record one column SHORT is refused, not read shifted",
     (await claimHeadOf('"orem"', 3)) === null);
  REPLY = REC + "\textra";
  ok("a record one column LONG is refused too",
     (await claimHeadOf('"orem"', 3)) === null);
  REPLY = "";
  ok("an empty reply is refused", (await claimHeadOf('"orem"', 3)) === null);
  {
    const bad = COLS.slice(); bad[0] = "not-a-number";
    REPLY = bad.join("\t");
    ok("a money column that is not a number is refused, not read as zero",
       (await claimHeadOf('"orem"', 3)) === null);
  }
  // 0 is a real answer for a pool and must NOT be mistaken for a parse failure
  {
    const zeroes = COLS.slice(); zeroes[0] = "0"; zeroes[1] = "0";
    REPLY = zeroes.join("\t");
    const z = await claimHeadOf('"orem"', 3);
    ok("but a genuinely zero pool is kept", z && z.yesStake === 0 && z.noStake === 0);
  }
  // an absent quorum/close is null rather than 0, because 0 is what the realm
  // sends for "no dispute is open" and the page tests these for presence
  {
    const nodispute = COLS.slice(); nodispute[22] = "0"; nodispute[23] = "0";
    REPLY = nodispute.join("\t");
    const z = await claimHeadOf('"orem"', 3);
    ok("no open round leaves quorum and close null, not zero",
       z && z.quorumFloor === null && z.voteCloses === null);
  }

  DONE = true;
  console.log(fail ? "\n" + fail + " FAILURES" : "\nALL PASS");
  process.exit(fail ? 1 : 0);
})();
